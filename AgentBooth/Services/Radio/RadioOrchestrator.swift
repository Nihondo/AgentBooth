import Foundation

/// Drives the radio playback lifecycle.
actor RadioOrchestrator {
    private let spotifyLeadCompensationSeconds = 0.35

    private struct PreparedNarration: Sendable {
        let script: RadioScript
        let wavData: Data
    }

    private struct ActiveNarration: Sendable {
        let prepared: PreparedNarration
        let playbackTask: Task<Void, Error>
        let durationSeconds: Double
    }

    private struct ResolvedNarration: Sendable {
        let prepared: PreparedNarration
        let didTrackReachNaturalEnd: Bool
    }

    private enum NarrationWaitOutcome {
        case narrationReady
        case naturalTrackEnd
    }

    private let settings: AppSettings
    private let musicService: any MusicService
    private let scriptService: any ScriptGenerationService
    private let ttsService: any TTSService
    private let audioPlaybackService: any AudioPlaybackServiceProtocol
    private let recordingService: (any ShowRecordingServiceProtocol)?
    private let stateDidChange: @Sendable (RadioState) -> Void

    private var radioState = RadioState()
    private var playbackTask: Task<Void, Never>?
    private var isStopRequested = false
    private var artistTopicHistory: [String: [String]] = [:]
    private var albumTopicHistory: [String: [String]] = [:]
    private var positionPollingTask: Task<Void, Never>?
    /// 曲の実再生開始時刻（再生位置が取れない場合のフォールバック用）
    private var trackStartedAt: ContinuousClock.Instant?

    init(
        settings: AppSettings,
        musicService: any MusicService,
        scriptService: any ScriptGenerationService,
        ttsService: any TTSService,
        audioPlaybackService: any AudioPlaybackServiceProtocol,
        recordingService: (any ShowRecordingServiceProtocol)? = nil,
        stateDidChange: @escaping @Sendable (RadioState) -> Void
    ) {
        self.settings = settings
        self.musicService = musicService
        self.scriptService = scriptService
        self.ttsService = ttsService
        self.audioPlaybackService = audioPlaybackService
        self.recordingService = recordingService
        self.stateDidChange = stateDidChange
    }

    func startShow(playlistName: String, initialTracks: [TrackInfo]? = nil) {
        guard playbackTask == nil else {
            return
        }
        isStopRequested = false
        updateState {
            $0.isRunning = true
            $0.isPaused = false
            $0.phase = .idle
            $0.playlistName = playlistName
            $0.overlapMode = settings.defaultOverlapMode
            $0.errorMessage = nil
            $0.currentTrack = nil
            $0.upcomingTracks = []
        }

        playbackTask = Task { [weak self] in
            await self?.runShow(playlistName: playlistName, initialTracks: initialTracks)
        }
    }

    func pauseShow() async {
        guard radioState.isRunning, !radioState.isPaused else {
            return
        }
        updateState { $0.isPaused = true }
        await musicService.pausePlayback()
        await audioPlaybackService.pausePlayback()
    }

    func resumeShow() async {
        guard radioState.isRunning, radioState.isPaused else {
            return
        }
        updateState { $0.isPaused = false }
        await musicService.resumePlayback()
        await audioPlaybackService.resumePlayback()
    }

    func stopShow() async {
        isStopRequested = true
        playbackTask?.cancel()
        playbackTask = nil
        stopPositionPolling()
        trackStartedAt = nil
        await audioPlaybackService.stopPlayback()
        await musicService.stopPlayback()
        resetState()
    }

    private func runShow(playlistName: String, initialTracks: [TrackInfo]? = nil) async {
        defer {
            playbackTask = nil
        }

        do {
            try await performShow(playlistName: playlistName, initialTracks: initialTracks)
            await finishRunShow(errorMessage: nil)
        } catch is CancellationError {
            await finishRunShow(errorMessage: nil)
        } catch {
            await finishRunShow(errorMessage: error.localizedDescription)
        }
    }

    private func performShow(playlistName: String, initialTracks: [TrackInfo]? = nil) async throws {
        let tracks = try await loadTracks(for: playlistName, initialTracks: initialTracks)
        let openingNarration = try await prepareOpeningNarration(tracks: tracks)
        rememberTopics(for: tracks[0], script: openingNarration.script)

        await startRecordingIfNeeded(playlistName: playlistName)

        var activeNarration = startNarration(openingNarration)

        for (indexValue, track) in tracks.enumerated() {
            try Task.checkCancellation()
            if isStopRequested {
                return
            }

            updateTrackState(track, trackIndex: indexValue)
            try await startTrackForActiveNarration(track: track, activeNarration: activeNarration)

            if isStopRequested {
                return
            }

            let nextTrack = indexValue + 1 < tracks.count ? tracks[indexValue + 1] : nil
            let completedTracks = Array(tracks.prefix(indexValue + 1))
            let nextNarrationTask = makeNextNarrationTask(
                currentTrack: track,
                nextTrack: nextTrack,
                completedTracks: completedTracks
            )
            defer { nextNarrationTask.cancel() }

            updateState { $0.phase = .playing }
            try await waitUntilOutroPoint(track: track)
            updateState { $0.phase = .outro }

            let resolvedNarration = try await resolveNextNarration(nextNarrationTask, for: track)
            if let nextTrack {
                rememberTopics(for: nextTrack, script: resolvedNarration.prepared.script)
            }
            let isClosingNarration = nextTrack == nil
            activeNarration = try await startResolvedNarration(
                resolvedNarration,
                after: track,
                isClosingNarration: isClosingNarration
            )
        }

        updateState { $0.phase = .closing }
        try await activeNarration.playbackTask.value
    }

    private func loadTracks(for playlistName: String, initialTracks: [TrackInfo]? = nil) async throws -> [TrackInfo] {
        let allTracks: [TrackInfo]
        if let initialTracks, !initialTracks.isEmpty {
            allTracks = initialTracks
        } else {
            allTracks = try await musicService.fetchTracks(in: playlistName)
        }
        let tracks = Array(allTracks.prefix(RadioConstants.maxTrackCount))
        guard !tracks.isEmpty else {
            throw CocoaError(
                .fileReadNoSuchFile,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "プレイリストに曲がありません。")]
            )
        }
        updateState {
            $0.upcomingTracks = tracks
            $0.phase = .opening
            $0.playlistTrackCount = tracks.count
            $0.trackIndex = 0
        }
        return tracks
    }

    private func startRecordingIfNeeded(playlistName: String) async {
        guard let recordingService else {
            return
        }
        let outputURL = makeRecordingOutputURL(playlistName: playlistName)
        do {
            try await recordingService.startRecording(outputURL: outputURL)
            updateState {
                $0.isRecording = true
                $0.recordingOutputURL = nil
            }
        } catch {
            updateState { $0.errorMessage = String(format: String(localized: "録音の開始に失敗しました: %@"), error.localizedDescription) }
        }
    }

    private func finishRunShow(errorMessage: String?) async {
        if let errorMessage {
            updateState { $0.errorMessage = errorMessage }
        }
        await audioPlaybackService.stopPlayback()
        await musicService.stopPlayback()
        await finalizeRecording()
        resetState()
    }

    private func finalizeRecording() async {
        guard let recordingService else { return }
        do {
            try await recordingService.stopRecording()
        } catch {
            updateState { $0.errorMessage = String(format: String(localized: "録音の保存に失敗しました: %@"), error.localizedDescription) }
        }
        let outputURL = radioState.recordingOutputURL
        updateState {
            $0.isRecording = false
            $0.recordingOutputURL = outputURL
        }
    }

    private func makeRecordingOutputURL(playlistName: String) -> URL {
        let baseDir: URL
        let customDir = settings.recordingOutputDirectory
        if customDir.isEmpty {
            baseDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentBooth", isDirectory: true)
        } else {
            baseDir = URL(fileURLWithPath: customDir, isDirectory: true)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let safeName = playlistName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let filename = "\(timestamp)_\(safeName).m4a"
        let outputURL = baseDir.appendingPathComponent(filename)
        updateState { $0.recordingOutputURL = outputURL }
        return outputURL
    }

    private func prepareOpeningNarration(tracks: [TrackInfo]) async throws -> PreparedNarration {
        updateState { $0.statusMessage = String(localized: "スクリプト作成開始（オープニング）"); $0.isProcessing = true }
        let script = try await scriptService.generateOpening(tracks: tracks, settings: settings)
        updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
        let wavData = try await synthesizeNarration(
            dialogues: script.dialogues,
            segmentLabel: String(localized: "オープニング")
        )
        return PreparedNarration(script: script, wavData: wavData)
    }

    private func makeNextNarrationTask(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo?,
        completedTracks: [TrackInfo]
    ) -> Task<PreparedNarration, Error> {
        Task {
            if let nextTrack {
                return try await generatePreparedTransitionNarration(
                    currentTrack: currentTrack,
                    nextTrack: nextTrack
                )
            }
            return try await generatePreparedClosingNarration(tracks: completedTracks)
        }
    }

    private func generatePreparedTransitionNarration(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo
    ) async throws -> PreparedNarration {
        let continuityNote = buildContinuityNote(for: nextTrack, previousTrack: currentTrack)
        updateState {
            $0.statusMessage = String(format: String(localized: "スクリプト作成開始（%@ → %@）"), currentTrack.name, nextTrack.name)
            $0.isProcessing = true
        }
        let script = try await scriptService.generateTransition(
            currentTrack: currentTrack,
            nextTrack: nextTrack,
            settings: settings,
            continuityNote: continuityNote
        )
        updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
        let wavData = try await synthesizeNarration(
            dialogues: script.dialogues,
            segmentLabel: String(format: String(localized: "%@ から %@ へのトランジション"), currentTrack.name, nextTrack.name)
        )
        return PreparedNarration(script: script, wavData: wavData)
    }

    private func generatePreparedClosingNarration(tracks: [TrackInfo]) async throws -> PreparedNarration {
        updateState { $0.statusMessage = String(localized: "スクリプト作成開始（クロージング）"); $0.isProcessing = true }
        let script = try await scriptService.generateClosing(tracks: tracks, settings: settings)
        updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
        let wavData = try await synthesizeNarration(
            dialogues: script.dialogues,
            segmentLabel: String(localized: "クロージング")
        )
        return PreparedNarration(script: script, wavData: wavData)
    }

    private func updateTrackState(_ track: TrackInfo, trackIndex: Int) {
        updateState {
            $0.currentTrack = track
            $0.trackIndex = trackIndex
            $0.currentPlaybackPosition = 0
            $0.phase = .intro
        }
    }

    private func startTrackForActiveNarration(
        track: TrackInfo,
        activeNarration: ActiveNarration
    ) async throws {
        let leadSeconds = effectiveMusicLeadSeconds()
        if settings.defaultOverlapMode == .enabled, leadSeconds > 0 {
            try await waitUntilNarrationRemainingSeconds(
                activeNarration,
                isAtMost: leadSeconds
            )
            try await startTrack(track, startVolume: settings.volumeSettings.talkVolume)
            try await activeNarration.playbackTask.value
            await fadeMusicVolume(
                targetVolume: settings.volumeSettings.normalVolume,
                durationSeconds: settings.volumeSettings.fadeDuration
            )
        } else {
            try await activeNarration.playbackTask.value
            try await startTrack(track, startVolume: settings.volumeSettings.normalVolume)
        }
    }

    private func startNarration(_ prepared: PreparedNarration) -> ActiveNarration {
        let playbackTask = Task {
            try await self.waitWhilePaused()
            try await self.audioPlaybackService.play(wavData: prepared.wavData)
        }
        return ActiveNarration(
            prepared: prepared,
            playbackTask: playbackTask,
            durationSeconds: wavDurationSeconds(prepared.wavData)
        )
    }

    private func waitUntilNarrationRemainingSeconds(
        _ activeNarration: ActiveNarration,
        isAtMost threshold: Double
    ) async throws {
        guard threshold > 0 else {
            return
        }
        let waitSeconds = max(0, activeNarration.durationSeconds - threshold)
        try await waitRespectingPause(seconds: waitSeconds)
    }

    private func effectiveMusicLeadSeconds() -> Double {
        max(0, settings.volumeSettings.musicLeadSeconds + estimatedTrackStartLatencySeconds())
    }

    private func estimatedTrackStartLatencySeconds() -> Double {
        switch musicService.serviceKind {
        case .spotify:
            return spotifyLeadCompensationSeconds
        case .appleMusic, .youtubeMusic:
            return 0
        }
    }

    private func resolveNextNarration(
        _ task: Task<PreparedNarration, Error>,
        for track: TrackInfo
    ) async throws -> ResolvedNarration {
        let didTrackReachNaturalEnd = try await waitUntilNarrationReadyOrNaturalEnd(task, track: track)
        if didTrackReachNaturalEnd {
            await stopTrackImmediately()
        }
        let prepared = try await task.value
        return ResolvedNarration(
            prepared: prepared,
            didTrackReachNaturalEnd: didTrackReachNaturalEnd
        )
    }

    private func waitUntilNarrationReadyOrNaturalEnd(
        _ task: Task<PreparedNarration, Error>,
        track: TrackInfo
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: NarrationWaitOutcome.self) { group in
            group.addTask {
                _ = try await task.value
                return .narrationReady
            }
            group.addTask { [weak self] in
                guard let self else {
                    throw CancellationError()
                }
                try await self.waitUntilNaturalTrackEnd(track: track)
                return .naturalTrackEnd
            }

            let outcome = try await group.next() ?? .narrationReady
            group.cancelAll()
            return outcome == .naturalTrackEnd
        }
    }

    private func startResolvedNarration(
        _ resolvedNarration: ResolvedNarration,
        after track: TrackInfo,
        isClosingNarration: Bool
    ) async throws -> ActiveNarration {
        if isClosingNarration {
            updateState { $0.phase = .closing }
        }

        if settings.defaultOverlapMode == .enabled, !resolvedNarration.didTrackReachNaturalEnd {
            await fadeMusicVolume(
                targetVolume: settings.volumeSettings.talkVolume,
                durationSeconds: settings.volumeSettings.fadeDuration
            )
            let activeNarration = startNarration(resolvedNarration.prepared)
            let fadeDuration = calculateFadeOutDuration()
            await fadeOutAndStopTrack(durationSeconds: fadeDuration)
            return activeNarration
        }

        await stopTrackImmediately()
        return startNarration(resolvedNarration.prepared)
    }

    private func setMusicVolume(level: Int) async {
        await musicService.setVolume(level: level)
        updateState { $0.volume = level }
    }

    private func startTrack(_ track: TrackInfo, startVolume: Int) async throws {
        await setMusicVolume(level: startVolume)
        try await musicService.play(track: track)
        await musicService.seekToPosition(0)
        await setMusicVolume(level: startVolume)
        trackStartedAt = ContinuousClock.now
        startPositionPolling(track: track)
    }

    private func stopTrackImmediately() async {
        stopPositionPolling()
        trackStartedAt = nil
        await musicService.stopPlayback()
        updateState { $0.currentPlaybackPosition = 0 }
    }

    private func synthesizeNarration(dialogues: [DialogueLine], segmentLabel: String) async throws -> Data {
        updateState { $0.statusMessage = String(format: String(localized: "TTS音声作成開始（%@）"), segmentLabel); $0.isProcessing = true }
        do {
            let result = try await ttsService.synthesize(dialogues: dialogues, settings: settings)
            let credentialLabel = result.credentialSetLabelUsed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "名称未設定")
                : result.credentialSetLabelUsed
            updateState {
                $0.statusMessage = String(
                    format: String(localized: "TTS音声作成終了（セット: %@ / モデル: %@）"),
                    credentialLabel,
                    result.modelUsed
                )
                $0.isProcessing = false
            }
            return result.wavData
        } catch {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "%@ の音声生成に失敗しました: %@"), segmentLabel, error.localizedDescription)]
            )
        }
    }

    /// 音楽サービスから取得した実際の再生位置がアウトロ開始位置に達するまでポーリング待機
    private func waitUntilOutroPoint(track: TrackInfo) async throws {
        let effectiveDuration = effectivePlaybackDuration(trackDurationSeconds: track.durationSeconds)
        let targetPosition = max(0, effectiveDuration - Double(settings.volumeSettings.fadeEarlySeconds))

        while !isStopRequested {
            try Task.checkCancellation()
            if await hasReachedPlaybackPosition(targetPosition) {
                return
            }
            try await waitRespectingPause(seconds: 0.5)
        }
    }

    private func waitUntilNaturalTrackEnd(track: TrackInfo) async throws {
        let naturalDuration = Double(track.durationSeconds)
        guard naturalDuration > 0 else {
            return
        }

        while !isStopRequested {
            try Task.checkCancellation()
            if await hasReachedPlaybackPosition(naturalDuration) {
                return
            }
            try await waitRespectingPause(seconds: 0.5)
        }
    }

    private func hasReachedPlaybackPosition(_ targetPosition: Double) async -> Bool {
        let position = await musicService.fetchPlaybackPosition()
        if position >= targetPosition {
            return true
        }
        guard let startedAt = trackStartedAt else {
            return false
        }
        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        return elapsedSeconds >= targetPosition
    }

    private func fadeOutAndStopTrack(durationSeconds: Double) async {
        stopPositionPolling()
        if durationSeconds > 0 {
            await fadeMusicVolume(targetVolume: 0, durationSeconds: durationSeconds)
        }
        trackStartedAt = nil
        await musicService.stopPlayback()
        updateState { $0.currentPlaybackPosition = 0 }
    }

    private func fadeMusicVolume(targetVolume: Int, durationSeconds: Double) async {
        let currentVolume = await musicService.fetchVolume()
        guard currentVolume != targetVolume else {
            return
        }

        let steps = 20
        let stepSize = Double(targetVolume - currentVolume) / Double(steps)
        let stepInterval = durationSeconds / Double(steps)

        for indexValue in 1...steps {
            if isStopRequested {
                return
            }
            let nextVolume = Int(Double(currentVolume) + stepSize * Double(indexValue))
            await musicService.setVolume(level: nextVolume)
            updateState { $0.volume = nextVolume }
            try? await Task.sleep(nanoseconds: UInt64(max(0, stepInterval) * 1_000_000_000))
        }
    }

    private func waitRespectingPause(seconds: Double) async throws {
        let totalSlices = Int(max(1, ceil(seconds / 0.2)))
        let sliceSeconds = seconds / Double(totalSlices)

        for _ in 0..<totalSlices {
            try Task.checkCancellation()
            if isStopRequested {
                throw CancellationError()
            }
            try await waitWhilePaused()
            try await Task.sleep(nanoseconds: UInt64(max(0.01, sliceSeconds) * 1_000_000_000))
        }
    }

    private func waitWhilePaused() async throws {
        while radioState.isPaused {
            try Task.checkCancellation()
            if isStopRequested {
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func rememberTopics(for track: TrackInfo, script: RadioScript) {
        let summaryEntries = topicSummaryEntries(for: track, script: script)
        for summaryEntry in summaryEntries {
            appendTopicSummary(summaryEntry, key: track.artist, store: &artistTopicHistory)
            appendTopicSummary(summaryEntry, key: track.album, store: &albumTopicHistory)
        }
    }

    private func buildContinuityNote(for track: TrackInfo, previousTrack: TrackInfo?) -> String? {
        guard let previousTrack else {
            return nil
        }

        var lines: [String] = []
        var shownEntries: Set<String> = []

        if previousTrack.artist == track.artist, let entries = artistTopicHistory[normalizeKey(track.artist)], !entries.isEmpty {
            lines.append("同一アーティストとして直前に触れた内容:")
            for entry in entries {
                lines.append("- \(entry)")
                shownEntries.insert(entry)
            }
        }

        if previousTrack.album == track.album, let entries = albumTopicHistory[normalizeKey(track.album)], !entries.isEmpty {
            let newEntries = entries.filter { !shownEntries.contains($0) }
            if !newEntries.isEmpty {
                lines.append("同一アルバムとして直前に触れた内容:")
                newEntries.forEach { lines.append("- \($0)") }
            }
        }

        guard !lines.isEmpty else {
            return nil
        }

        lines.append("重複しそうなら別の観点に切り替えること。")
        return lines.joined(separator: "\n")
    }

    private func appendTopicSummary(_ summary: String, key: String, store: inout [String: [String]]) {
        let normalizedKey = normalizeKey(key)
        guard !normalizedKey.isEmpty else {
            return
        }
        var entries = store[normalizedKey, default: []]
        if !entries.contains(summary) {
            entries.append(summary)
        }
        if entries.count > 2 {
            entries = Array(entries.suffix(2))
        }
        store[normalizedKey] = entries
    }

    private func normalizeKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func topicSummaryEntries(for track: TrackInfo, script: RadioScript) -> [String] {
        let normalizedBullets = script.summaryBullets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedBullets.isEmpty {
            return normalizedBullets.map { "\(track.name): \($0)" }
        }

        let fallbackText = script.dialogues.prefix(4)
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: " / ")
        guard !fallbackText.isEmpty else {
            return []
        }
        return ["\(track.name): \(fallbackText)"]
    }

    private func calculateFadeOutDuration() -> Double {
        max(0, settings.volumeSettings.fadeDuration)
    }

    private func effectivePlaybackDuration(trackDurationSeconds: Int) -> Double {
        let maxPlayback = Double(settings.volumeSettings.maxPlaybackDurationSeconds)
        let trackDuration = Double(trackDurationSeconds)
        guard maxPlayback > 0 else {
            return trackDuration
        }
        return min(trackDuration, maxPlayback)
    }

    private func wavDurationSeconds(_ wavData: Data) -> Double {
        guard wavData.count > 44 else {
            return 0
        }
        let pcmBytes = wavData.count - 44
        let bytesPerSecond = 24_000 * 2
        return Double(pcmBytes) / Double(bytesPerSecond)
    }

    /// 曲の再生開始時に呼び出し、音楽サービスから再生位置を定期取得してStateを更新するポーリングを開始する
    private func startPositionPolling(track: TrackInfo) {
        stopPositionPolling()
        let effectiveDuration = effectivePlaybackDuration(trackDurationSeconds: track.durationSeconds)
        positionPollingTask = Task {
            while !Task.isCancelled {
                let position = await self.musicService.fetchPlaybackPosition()
                self.updateState { $0.currentPlaybackPosition = position }
                if position >= effectiveDuration { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// ポーリングタスクを停止して再生位置をリセットする
    private func stopPositionPolling() {
        positionPollingTask?.cancel()
        positionPollingTask = nil
    }

    private func updateState(_ mutateState: (inout RadioState) -> Void) {
        mutateState(&radioState)
        stateDidChange(radioState)
    }

    private func resetState() {
        trackStartedAt = nil
        updateState {
            $0.isRunning = false
            $0.isPaused = false
            $0.phase = .idle
            $0.currentTrack = nil
            $0.upcomingTracks = []
            $0.volume = settings.volumeSettings.normalVolume
            $0.statusMessage = ""
            $0.isProcessing = false
            $0.isRecording = false
            $0.trackIndex = 0
            $0.playlistTrackCount = 0
            $0.currentPlaybackPosition = 0
            // recordingOutputURL は番組終了後もユーザーが確認できるよう保持する
        }
    }
}
