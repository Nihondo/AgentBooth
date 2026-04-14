import Foundation

/// Drives the radio playback lifecycle.
actor RadioOrchestrator {
    private enum TrackPlaybackOutcome {
        case startedNextTrackViaTransition
        case finishedCurrentTrackOnly
        case finishedFinalTrack
        case stopped

        var didStartNextTrack: Bool {
            switch self {
            case .startedNextTrackViaTransition:
                return true
            case .finishedCurrentTrackOnly, .finishedFinalTrack, .stopped:
                return false
            }
        }
    }

    private enum TrackStartInstruction {
        case playOpeningNarration(PreparedNarration)
        case startTrackOnly
        case trackAlreadyStarted
    }

    private struct PreparedNarration: Sendable {
        let script: RadioScript
        let wavData: Data
    }

    private enum PreparationSnapshot<Value: Sendable> {
        case pending
        case ready(Value)
        case failed(String)
        case cancelled
    }

    private enum TimedNarrationPreparation<Value: Sendable> {
        case ready(Value)
        case notReadyAtDeadline
        case failed(String)
        case cancelled
    }

    private actor PreparationStore<Value: Sendable> {
        private var snapshot: PreparationSnapshot<Value> = .pending

        func save(_ value: PreparationSnapshot<Value>) {
            snapshot = value
        }

        func load() -> PreparationSnapshot<Value> {
            snapshot
        }
    }

    private final class TimedPreparation<Value: Sendable>: @unchecked Sendable {
        private let store: PreparationStore<Value>
        private let task: Task<Void, Never>

        init(operation: @escaping @Sendable () async throws -> Value) {
            let store = PreparationStore<Value>()
            self.store = store
            self.task = Task {
                do {
                    let value = try await operation()
                    await store.save(.ready(value))
                } catch is CancellationError {
                    await store.save(.cancelled)
                } catch {
                    await store.save(.failed(error.localizedDescription))
                }
            }
        }

        func snapshot() async -> PreparationSnapshot<Value> {
            await store.load()
        }

        func cancel() {
            task.cancel()
        }
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
    /// 曲の実再生開始時刻（アウトロポイント計算のフォールバック用）
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

    func startShow(playlistName: String, overlapMode: OverlapMode) {
        guard playbackTask == nil else {
            return
        }
        isStopRequested = false
        updateState {
            $0.isRunning = true
            $0.isPaused = false
            $0.phase = .idle
            $0.playlistName = playlistName
            $0.overlapMode = overlapMode
            $0.errorMessage = nil
            $0.currentTrack = nil
            $0.upcomingTracks = []
        }

        playbackTask = Task { [weak self] in
            await self?.runShow(playlistName: playlistName, overlapMode: overlapMode)
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
        trackStartedAt = nil
        stopPositionPolling()
        await audioPlaybackService.stopPlayback()
        await musicService.stopPlayback()
        resetState()
    }

    private func runShow(playlistName: String, overlapMode: OverlapMode) async {
        var closingTask: Task<PreparedNarration, Error>?
        defer {
            closingTask?.cancel()
            playbackTask = nil
        }

        do {
            try await performShow(playlistName: playlistName, overlapMode: overlapMode, closingTask: &closingTask)
            await finishRunShow(errorMessage: nil)
        } catch is CancellationError {
            await finishRunShow(errorMessage: nil)
        } catch {
            await finishRunShow(errorMessage: error.localizedDescription)
        }
    }

    private func performShow(
        playlistName: String,
        overlapMode: OverlapMode,
        closingTask: inout Task<PreparedNarration, Error>?
    ) async throws {
        let tracks = try await loadTracks(for: playlistName)
        let openingNarration = try await prepareOpeningNarration(tracks: tracks)
        rememberTopics(for: tracks[0], script: openingNarration.script)

        // オープニング音声の準備が完了した直後に録音を開始する。
        // これにより、録音冒頭の無音時間（CLI/TTS の処理待ち）を排除する。
        await startRecordingIfNeeded(playlistName: playlistName)

        var playedTracks: [TrackInfo] = []
        var previousOutcome: TrackPlaybackOutcome?

        for (indexValue, track) in tracks.enumerated() {
            try Task.checkCancellation()
            if isStopRequested {
                return
            }

            let previousTrack = indexValue > 0 ? tracks[indexValue - 1] : nil
            let nextTrack = indexValue + 1 < tracks.count ? tracks[indexValue + 1] : nil
            if nextTrack == nil && closingTask == nil {
                let closingTracks = playedTracks + [track]
                closingTask = prepareClosingNarration(tracks: closingTracks)
            }

            let startInstruction = await determineTrackStartInstruction(
                indexValue: indexValue,
                openingNarration: openingNarration,
                previousOutcome: previousOutcome
            )
            let introPreparation = makeIntroPreparationIfNeeded(
                track: track,
                previousTrack: previousTrack,
                overlapMode: overlapMode
            )
            let outcome = try await playTrack(
                track: track,
                nextTrack: nextTrack,
                overlapMode: overlapMode,
                startInstruction: startInstruction,
                trackIndex: indexValue,
                introPreparation: introPreparation
            )

            playedTracks.append(track)
            previousOutcome = outcome
        }

        try await playClosingIfNeeded(tracks: playedTracks, closingTask: closingTask)
    }

    private func loadTracks(for playlistName: String) async throws -> [TrackInfo] {
        let tracks = try await musicService.fetchTracks(in: playlistName)
        guard !tracks.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: String(localized: "プレイリストに曲がありません。")])
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

    private func prepareClosingNarration(tracks: [TrackInfo]) -> Task<PreparedNarration, Error> {
        Task {
            try await generatePreparedClosingNarration(tracks: tracks)
        }
    }

    private func generatePreparedClosingNarration(tracks: [TrackInfo]) async throws -> PreparedNarration {
        updateState { $0.statusMessage = String(localized: "スクリプト作成開始（クロージング）"); $0.isProcessing = true }
        let closingScript = try await scriptService.generateClosing(tracks: tracks, settings: settings)
        updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
        let wavData = try await synthesizeNarration(
            dialogues: closingScript.dialogues,
            segmentLabel: String(localized: "クロージング")
        )
        return PreparedNarration(script: closingScript, wavData: wavData)
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

    private func prepareTransitionNarration(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo
    ) -> TimedPreparation<PreparedNarration> {
        TimedPreparation { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.generatePreparedTransitionNarration(
                currentTrack: currentTrack,
                nextTrack: nextTrack
            )
        }
    }

    private func prepareIntroNarration(
        track: TrackInfo,
        previousTrack: TrackInfo
    ) -> TimedPreparation<PreparedNarration> {
        TimedPreparation { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.generatePreparedIntroNarration(track: track, previousTrack: previousTrack)
        }
    }

    private func generatePreparedIntroNarration(
        track: TrackInfo,
        previousTrack: TrackInfo
    ) async throws -> PreparedNarration {
        let continuityNote = buildContinuityNote(for: track, previousTrack: previousTrack)
        updateState { $0.statusMessage = String(format: String(localized: "スクリプト作成開始（%@ のイントロ）"), track.name); $0.isProcessing = true }
        let script = try await scriptService.generateIntro(
            track: track,
            settings: settings,
            continuityNote: continuityNote
        )
        updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
        let wavData = try await synthesizeNarration(
            dialogues: script.dialogues,
            segmentLabel: String(format: String(localized: "%@ のイントロ"), track.name)
        )
        return PreparedNarration(script: script, wavData: wavData)
    }

    private func generatePreparedTransitionNarration(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo
    ) async throws -> PreparedNarration {
        let continuityNote = buildContinuityNote(for: nextTrack, previousTrack: currentTrack)
        updateState { $0.statusMessage = String(format: String(localized: "スクリプト作成開始（%@ → %@）"), currentTrack.name, nextTrack.name); $0.isProcessing = true }
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

    private func determineTrackStartInstruction(
        indexValue: Int,
        openingNarration: PreparedNarration,
        previousOutcome: TrackPlaybackOutcome?
    ) async -> TrackStartInstruction {
        if indexValue == 0 {
            return .playOpeningNarration(openingNarration)
        }

        if previousOutcome?.didStartNextTrack == true {
            return .trackAlreadyStarted
        }

        return .startTrackOnly
    }

    private func playClosingIfNeeded(
        tracks: [TrackInfo],
        closingTask: Task<PreparedNarration, Error>?
    ) async throws {
        guard !isStopRequested else {
            return
        }
        updateState { $0.phase = .closing }
        let narration: PreparedNarration
        if let closingTask {
            narration = try await closingTask.value
        } else {
            narration = try await generatePreparedClosingNarration(tracks: tracks)
        }
        try await playStandaloneNarration(wavData: narration.wavData)
    }

    private func playTrack(
        track: TrackInfo,
        nextTrack: TrackInfo?,
        overlapMode: OverlapMode,
        startInstruction: TrackStartInstruction,
        trackIndex: Int,
        introPreparation: TimedPreparation<PreparedNarration>?
    ) async throws -> TrackPlaybackOutcome {
        try await playIntroIfNeeded(
            track: track,
            overlapMode: overlapMode,
            startInstruction: startInstruction,
            trackIndex: trackIndex,
            fadeIn: trackIndex == 0
        )

        if isStopRequested {
            return .stopped
        }

        updateState { $0.phase = .playing }
        if overlapMode == .introOver, let introPreparation {
            try await playMidTrackIntroIfNeeded(track: track, introPreparation: introPreparation)
        }
        let transitionPreparation: TimedPreparation<PreparedNarration>? = if overlapMode == .introOver {
            nil
        } else {
            nextTrack.map { prepareTransitionNarration(currentTrack: track, nextTrack: $0) }
        }
        try await waitUntilOutroPoint(track: track)
        return try await handleTrackEnding(
            track: track,
            nextTrack: nextTrack,
            transitionPreparation: transitionPreparation,
            overlapMode: overlapMode
        )
    }

    private func playIntroIfNeeded(
        track: TrackInfo,
        overlapMode: OverlapMode,
        startInstruction: TrackStartInstruction,
        trackIndex: Int,
        fadeIn: Bool = false
    ) async throws {
        updateState {
            $0.currentTrack = track
            $0.trackIndex = trackIndex
            $0.currentPlaybackPosition = 0
        }

        switch startInstruction {
        case .trackAlreadyStarted:
            return
        case .startTrackOnly:
            updateState { $0.phase = .intro }
            try await startTrack(track, fadeIn: fadeIn)
        case .playOpeningNarration(let narration):
            updateState { $0.phase = .intro }
            rememberTopics(for: track, script: narration.script)
            switch overlapMode {
            case .introOver, .fullRadio:
                try await playNarrationWithMusicLead(wavData: narration.wavData, track: track, fadeIn: fadeIn)
            default:
                try await playStandaloneNarration(wavData: narration.wavData)
                try await startTrack(track, fadeIn: fadeIn)
            }
        }
    }

    private func makeIntroPreparationIfNeeded(
        track: TrackInfo,
        previousTrack: TrackInfo?,
        overlapMode: OverlapMode
    ) -> TimedPreparation<PreparedNarration>? {
        guard overlapMode == .introOver, let previousTrack else {
            return nil
        }
        return prepareIntroNarration(track: track, previousTrack: previousTrack)
    }

    private func playMidTrackIntroIfNeeded(
        track: TrackInfo,
        introPreparation: TimedPreparation<PreparedNarration>
    ) async throws {
        let introStartSeconds = Double(settings.volumeSettings.speakAfterSeconds)
        let outroStartSeconds = max(0, effectivePlaybackDuration(trackDurationSeconds: track.durationSeconds) - Double(settings.volumeSettings.fadeEarlySeconds))

        guard introStartSeconds < outroStartSeconds else {
            introPreparation.cancel()
            updateState { $0.statusMessage = String(format: String(localized: "%@ のイントロは再生位置が遅すぎるためスキップしました。"), track.name) }
            return
        }

        try await waitRespectingPause(seconds: introStartSeconds)

        let introResult = await resolvePreparationAtDeadline(
            introPreparation,
            segmentName: String(format: String(localized: "%@ のイントロ"), track.name)
        )
        guard case .ready(let narration) = introResult else {
            return
        }

        let narrationDuration = wavDurationSeconds(narration.wavData)
        let requiredWindow = max(narrationDuration, settings.volumeSettings.fadeDuration)
            + settings.volumeSettings.fadeDuration
        let availableWindow = max(0, outroStartSeconds - introStartSeconds)
        guard requiredWindow <= availableWindow else {
            updateState { $0.statusMessage = String(format: String(localized: "%@ のイントロは再生時間に収まらないためスキップしました。"), track.name) }
            return
        }

        updateState { $0.phase = .intro }
        rememberTopics(for: track, script: narration.script)
        try await playNarrationOverCurrentTrack(wavData: narration.wavData)
        updateState { $0.phase = .playing }
    }

    private func playNarrationOverCurrentTrack(wavData: Data) async throws {
        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        async let duckTask: Void = fadeMusicVolume(
            targetVolume: settings.volumeSettings.talkVolume,
            durationSeconds: settings.volumeSettings.fadeDuration
        )

        _ = try await (narrationTask, duckTask)
        await fadeMusicVolume(
            targetVolume: settings.volumeSettings.normalVolume,
            durationSeconds: settings.volumeSettings.fadeDuration
        )
    }

    /// 音楽サービスから取得した実際の再生位置がアウトロ開始位置に達するまでポーリング待機
    /// 音楽サービスから取得した実際の再生位置がアウトロ開始位置に達するまでポーリング待機
    private func waitUntilOutroPoint(track: TrackInfo) async throws {
        let effectiveDuration = effectivePlaybackDuration(trackDurationSeconds: track.durationSeconds)
        let targetPosition = max(0, effectiveDuration - Double(settings.volumeSettings.fadeEarlySeconds))

        while !isStopRequested {
            try Task.checkCancellation()
            let position = await musicService.fetchPlaybackPosition()
            if position >= targetPosition { return }
            // フォールバック: 再生位置が取得できない場合は経過時間で判定
            if let startedAt = trackStartedAt {
                let elapsed = ContinuousClock.now - startedAt
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                if elapsedSeconds >= targetPosition { return }
            }
            try await waitRespectingPause(seconds: 0.5)
        }
    }

    private func handleTrackEnding(
        track: TrackInfo,
        nextTrack: TrackInfo?,
        transitionPreparation: TimedPreparation<PreparedNarration>?,
        overlapMode: OverlapMode
    ) async throws -> TrackPlaybackOutcome {
        updateState { $0.phase = .outro }

        if let nextTrack {
            let transitionResult = await resolvePreparationAtDeadline(
                transitionPreparation,
                segmentName: "\(track.name) から \(nextTrack.name) へのトランジション"
            )
            switch transitionResult {
            case .ready(let narration):
                rememberTopics(for: nextTrack, script: narration.script)
                switch overlapMode {
                case .outroOver:
                    try await playTransitionWithOutroOverlap(
                        wavData: narration.wavData,
                        currentTrackDurationSeconds: track.durationSeconds
                    )
                    return .finishedCurrentTrackOnly
                case .fullRadio:
                    try await playTransitionWithFullRadioOverlap(
                        wavData: narration.wavData,
                        currentTrackDurationSeconds: track.durationSeconds,
                        nextTrack: nextTrack
                    )
                    return .startedNextTrackViaTransition
                default:
                    let fadeDuration = await calculateFadeOutDuration(trackDurationSeconds: track.durationSeconds)
                    await fadeOutAndStopTrack(durationSeconds: fadeDuration)
                    try await playTransition(wavData: narration.wavData, nextTrack: nextTrack)
                    return .startedNextTrackViaTransition
                }
            case .notReadyAtDeadline, .failed, .cancelled:
                let fadeDuration = await calculateFadeOutDuration(trackDurationSeconds: track.durationSeconds)
                await fadeOutAndStopTrack(durationSeconds: fadeDuration)
                return .finishedCurrentTrackOnly
            }
        }

        let fadeDuration = await calculateFadeOutDuration(trackDurationSeconds: track.durationSeconds)
        await fadeOutAndStopTrack(durationSeconds: fadeDuration)
        return .finishedFinalTrack
    }

    private func resolvePreparationAtDeadline<Value: Sendable>(
        _ preparation: TimedPreparation<Value>?,
        segmentName: String
    ) async -> TimedNarrationPreparation<Value> {
        guard let preparation else {
            return .cancelled
        }

        let snapshot = await preparation.snapshot()
        switch snapshot {
        case .ready(let value):
            return .ready(value)
        case .pending:
            preparation.cancel()
            updateState { $0.statusMessage = String(format: String(localized: "%@ は再生タイミングに間に合わなかったためスキップしました。"), segmentName) }
            return .notReadyAtDeadline
        case .failed(let errorMessage):
            updateState { $0.statusMessage = String(format: String(localized: "%@ は音声生成に失敗したためスキップしました。"), segmentName) }
            updateState { $0.errorMessage = errorMessage }
            return .failed(errorMessage)
        case .cancelled:
            return .cancelled
        }
    }

    private func fadeOutAndStopTrack(durationSeconds: Double) async {
        stopPositionPolling()
        if durationSeconds > 0 {
            await fadeMusicVolume(targetVolume: 0, durationSeconds: durationSeconds)
        }
        await musicService.stopPlayback()
    }

    private func setMusicVolume(level: Int) async {
        await musicService.setVolume(level: level)
        updateState { $0.volume = level }
    }

    private func startTrack(_ track: TrackInfo, fadeIn: Bool = false) async throws {
        let startVolume = fadeIn ? settings.volumeSettings.talkVolume : settings.volumeSettings.normalVolume
        await setMusicVolume(level: startVolume)
        try await musicService.play(track: track)
        await musicService.seekToPosition(0)
        trackStartedAt = ContinuousClock.now
        startPositionPolling(track: track)
        if fadeIn {
            await fadeMusicVolume(targetVolume: settings.volumeSettings.normalVolume, durationSeconds: settings.volumeSettings.fadeDuration)
        }
    }

    private func playStandaloneNarration(wavData: Data) async throws {
        try await waitWhilePaused()
        try await audioPlaybackService.play(wavData: wavData)
    }

    private func synthesizeNarration(dialogues: [DialogueLine], segmentLabel: String) async throws -> Data {
        updateState { $0.statusMessage = String(format: String(localized: "TTS音声作成開始（%@）"), segmentLabel); $0.isProcessing = true }
        do {
            let result = try await ttsService.synthesize(dialogues: dialogues, settings: settings)
            let isFallback = result.modelUsed != settings.geminiTTSModel
            if isFallback {
                updateState { $0.statusMessage = String(format: String(localized: "TTS音声作成終了（副モデル: %@）"), result.modelUsed); $0.isProcessing = false }
            } else {
                updateState { $0.statusMessage = String(localized: "TTS音声作成終了"); $0.isProcessing = false }
            }
            return result.wavData
        } catch {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "%@ の音声生成に失敗しました: %@"), segmentLabel, error.localizedDescription)]
            )
        }
    }

    private func playNarrationWithMusicLead(wavData: Data, track: TrackInfo, fadeIn: Bool = false) async throws {
        let durationSeconds = wavDurationSeconds(wavData)
        let startDelay = max(0, durationSeconds - settings.volumeSettings.musicLeadSeconds)
        let startVolume = fadeIn ? settings.volumeSettings.talkVolume : settings.volumeSettings.normalVolume

        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        async let startTask: Void = startTrackAfterDelay(track: track, delaySeconds: startDelay, startVolume: startVolume)
        _ = try await (narrationTask, startTask)
        if fadeIn {
            await fadeMusicVolume(targetVolume: settings.volumeSettings.normalVolume, durationSeconds: settings.volumeSettings.fadeDuration)
        }
    }

    private func playTransition(wavData: Data, nextTrack: TrackInfo) async throws {
        let durationSeconds = wavDurationSeconds(wavData)
        let startDelay = max(0, durationSeconds - settings.volumeSettings.musicLeadSeconds)

        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        async let startTask: Void = startTrackAfterDelay(track: nextTrack, delaySeconds: startDelay, startVolume: settings.volumeSettings.talkVolume)
        _ = try await (narrationTask, startTask)
        await fadeMusicVolume(targetVolume: settings.volumeSettings.normalVolume, durationSeconds: settings.volumeSettings.fadeDuration)
    }

    private func playTransitionWithOutroOverlap(
        wavData: Data,
        currentTrackDurationSeconds: Int
    ) async throws {
        await setMusicVolume(level: settings.volumeSettings.talkVolume)

        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        async let outroTask: Void = finishCurrentTrackAtEffectiveEnd(trackDurationSeconds: currentTrackDurationSeconds)
        _ = try await (narrationTask, outroTask)
    }

    private func playTransitionWithFullRadioOverlap(
        wavData: Data,
        currentTrackDurationSeconds: Int,
        nextTrack: TrackInfo
    ) async throws {
        await setMusicVolume(level: settings.volumeSettings.talkVolume)

        let narrationDuration = wavDurationSeconds(wavData)
        let nextTrackDesiredDelay = max(0, narrationDuration - settings.volumeSettings.musicLeadSeconds)
        let outgoingTrackTask = Task {
            try await self.finishCurrentTrackAtEffectiveEnd(trackDurationSeconds: currentTrackDurationSeconds)
        }

        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        let nextTrackTask = Task {
            try await self.waitRespectingPause(seconds: nextTrackDesiredDelay)
            try await outgoingTrackTask.value
            try await self.startTrackAfterDelay(
                track: nextTrack,
                delaySeconds: 0,
                startVolume: self.settings.volumeSettings.talkVolume
            )
        }

        _ = try await narrationTask
        try await nextTrackTask.value
        await fadeMusicVolume(
            targetVolume: settings.volumeSettings.normalVolume,
            durationSeconds: settings.volumeSettings.fadeDuration
        )
    }

    private func finishCurrentTrackAtEffectiveEnd(trackDurationSeconds: Int) async throws {
        let remainingSeconds = await remainingPlaybackSeconds(trackDurationSeconds: trackDurationSeconds)
        let finalFadeDuration = min(settings.volumeSettings.fadeDuration, remainingSeconds)
        let delayBeforeFinalFade = max(0, remainingSeconds - finalFadeDuration)

        try await waitRespectingPause(seconds: delayBeforeFinalFade)
        let fadeDuration = await calculateFadeOutDuration(trackDurationSeconds: trackDurationSeconds)
        await fadeOutAndStopTrack(durationSeconds: fadeDuration)
    }

    private func startTrackAfterDelay(track: TrackInfo, delaySeconds: Double, startVolume: Int? = nil) async throws {
        try await waitRespectingPause(seconds: delaySeconds)
        if let startVolume {
            await setMusicVolume(level: startVolume)
        }
        try await musicService.play(track: track)
        await musicService.seekToPosition(0)
        trackStartedAt = ContinuousClock.now
        startPositionPolling(track: track)
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
            try? await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
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

        if previousTrack.artist == track.artist, let entries = artistTopicHistory[normalizeKey(track.artist)], !entries.isEmpty {
            lines.append("同一アーティストとして直前に触れた内容:")
            lines.append(contentsOf: entries.map { "- \($0)" })
        }

        if previousTrack.album == track.album, let entries = albumTopicHistory[normalizeKey(track.album)], !entries.isEmpty {
            lines.append("同一アルバムとして直前に触れた内容:")
            lines.append(contentsOf: entries.map { "- \($0)" })
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

    private func calculateFadeOutDuration(trackDurationSeconds: Int) async -> Double {
        let remainingSeconds = await remainingPlaybackSeconds(trackDurationSeconds: trackDurationSeconds)
        return min(Double(settings.volumeSettings.fadeEarlySeconds), remainingSeconds)
    }

    private func effectivePlaybackDuration(trackDurationSeconds: Int) -> Double {
        let maxPlayback = Double(settings.volumeSettings.maxPlaybackDurationSeconds)
        let trackDuration = Double(trackDurationSeconds)
        guard maxPlayback > 0 else {
            return trackDuration
        }
        return min(trackDuration, maxPlayback)
    }

    /// 音楽サービスから実際の再生位置を取得し、残り再生可能秒数を返す
    private func remainingPlaybackSeconds(trackDurationSeconds: Int) async -> Double {
        let effectiveDuration = effectivePlaybackDuration(trackDurationSeconds: trackDurationSeconds)
        let position = await musicService.fetchPlaybackPosition()
        if position > 0 {
            return max(0, effectiveDuration - position)
        }
        if let startedAt = trackStartedAt {
            let elapsed = ContinuousClock.now - startedAt
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            return max(0, effectiveDuration - elapsedSeconds)
        }
        return max(0, effectiveDuration - position)
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
                // 有効再生時間に達したらポーリングを終了
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
