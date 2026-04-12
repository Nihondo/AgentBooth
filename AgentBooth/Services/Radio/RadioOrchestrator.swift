import Foundation

/// Drives the radio playback lifecycle.
actor RadioOrchestrator {
    private let settings: AppSettings
    private let musicService: any MusicService
    private let scriptService: any ScriptGenerationService
    private let ttsService: any TTSService
    private let audioPlaybackService: any AudioPlaybackServiceProtocol
    private let stateDidChange: @Sendable (RadioState) -> Void

    private var radioState = RadioState()
    private var playbackTask: Task<Void, Never>?
    private var isStopRequested = false
    private var artistTopicHistory: [String: [String]] = [:]
    private var albumTopicHistory: [String: [String]] = [:]
    private var trackStartedAt: ContinuousClock.Instant?

    init(
        settings: AppSettings,
        musicService: any MusicService,
        scriptService: any ScriptGenerationService,
        ttsService: any TTSService,
        audioPlaybackService: any AudioPlaybackServiceProtocol,
        stateDidChange: @escaping @Sendable (RadioState) -> Void
    ) {
        self.settings = settings
        self.musicService = musicService
        self.scriptService = scriptService
        self.ttsService = ttsService
        self.audioPlaybackService = audioPlaybackService
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
        await audioPlaybackService.stopPlayback()
        await musicService.stopPlayback()
        resetState()
    }

    private func runShow(playlistName: String, overlapMode: OverlapMode) async {
        defer {
            playbackTask = nil
        }

        do {
            let tracks = try await musicService.fetchTracks(in: playlistName)
            guard !tracks.isEmpty else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "プレイリストに曲がありません。"])
            }

            updateState {
                $0.upcomingTracks = tracks
                $0.phase = .opening
            }

            updateState { $0.statusMessage = "スクリプト作成開始（オープニング）" }
            let openingScript = try await scriptService.generateOpening(tracks: tracks, settings: settings)
            updateState { $0.statusMessage = "スクリプト作成終了" }
            let openingWAV = try await synthesizeNarration(
                dialogues: openingScript.dialogues,
                segmentLabel: "オープニング"
            )
            rememberTopics(for: tracks[0], script: openingScript)

            var playedTracks: [TrackInfo] = []

            for (indexValue, track) in tracks.enumerated() {
                try Task.checkCancellation()
                if isStopRequested {
                    return
                }

                let nextTrack = indexValue + 1 < tracks.count ? tracks[indexValue + 1] : nil
                let introScript: RadioScript
                let introWAV: Data

                if indexValue == 0 {
                    introScript = openingScript
                    introWAV = openingWAV
                } else {
                    let continuityNote = buildContinuityNote(for: track, previousTrack: tracks[indexValue - 1])
                    updateState { $0.statusMessage = "スクリプト作成開始（\(track.name) のイントロ）" }
                    introScript = try await scriptService.generateIntro(
                        track: track,
                        settings: settings,
                        continuityNote: continuityNote
                    )
                    updateState { $0.statusMessage = "スクリプト作成終了" }
                    rememberTopics(for: track, script: introScript)
                    introWAV = try await synthesizeNarration(
                        dialogues: introScript.dialogues,
                        segmentLabel: "\(track.name) のイントロ"
                    )
                }

                try await playTrack(
                    track: track,
                    nextTrack: nextTrack,
                    introScript: introScript,
                    introWAV: introWAV,
                    overlapMode: overlapMode
                )
                playedTracks.append(track)
            }

            if !isStopRequested {
                updateState { $0.phase = .closing }
                updateState { $0.statusMessage = "スクリプト作成開始（クロージング）" }
                let closingScript = try await scriptService.generateClosing(tracks: playedTracks, settings: settings)
                updateState { $0.statusMessage = "スクリプト作成終了" }
                let closingWAV = try await synthesizeNarration(
                    dialogues: closingScript.dialogues,
                    segmentLabel: "クロージング"
                )
                try await playStandaloneNarration(wavData: closingWAV)
            }

            resetState()
        } catch is CancellationError {
            await audioPlaybackService.stopPlayback()
            await musicService.stopPlayback()
            resetState()
        } catch {
            updateState { stateValue in
                stateValue.errorMessage = error.localizedDescription
            }
            await audioPlaybackService.stopPlayback()
            await musicService.stopPlayback()
            resetState()
        }
    }

    private func playTrack(
        track: TrackInfo,
        nextTrack: TrackInfo?,
        introScript: RadioScript,
        introWAV: Data,
        overlapMode: OverlapMode
    ) async throws {
        updateState {
            $0.currentTrack = track
            $0.phase = .intro
        }

        switch overlapMode {
        case .introOver, .fullRadio:
            try await playNarrationWithMusicLead(wavData: introWAV, track: track)
        default:
            try await playStandaloneNarration(wavData: introWAV)
            try await startTrack(track)
        }

        if isStopRequested {
            return
        }

        updateState { $0.phase = .playing }

        let transitionTask: Task<(RadioScript, Data)?, Error>? = nextTrack.map { upcomingTrack in
            Task {
                let continuityNote = buildContinuityNote(for: upcomingTrack, previousTrack: track)
                updateState { $0.statusMessage = "スクリプト作成開始（\(track.name) → \(upcomingTrack.name)）" }
                let transitionScript = try await scriptService.generateTransition(
                    currentTrack: track,
                    nextTrack: upcomingTrack,
                    settings: settings,
                    continuityNote: continuityNote
                )
                updateState { $0.statusMessage = "スクリプト作成終了" }
                rememberTopics(for: upcomingTrack, script: transitionScript)
                let transitionWAV = try await synthesizeNarration(
                    dialogues: transitionScript.dialogues,
                    segmentLabel: "\(track.name) から \(upcomingTrack.name) へのトランジション"
                )
                return (transitionScript, transitionWAV)
            }
        }

        let firstWaitSeconds = calculateWaitBeforeTransition(
            trackDurationSeconds: track.durationSeconds,
            fadeEarlySeconds: settings.volumeSettings.fadeEarlySeconds
        )
        try await waitRespectingPause(seconds: firstWaitSeconds)

        if let transitionTask, let upcomingTrack = nextTrack {
            updateState { $0.phase = .outro }
            let preparedTransition = try await transitionTask.value
            if let (_, transitionWAV) = preparedTransition {
                await fadeMusicVolume(targetVolume: settings.volumeSettings.talkVolume, durationSeconds: settings.volumeSettings.fadeDuration)
                await musicService.stopPlayback()
                try await playTransition(wavData: transitionWAV, nextTrack: upcomingTrack)
                return
            }
        }

        let secondWaitSeconds = Double(nextTrack == nil ? settings.volumeSettings.fadeEarlySeconds : 0)
        if secondWaitSeconds > 0 {
            try await waitRespectingPause(seconds: secondWaitSeconds)
            await musicService.stopPlayback()
        }
    }

    private func startTrack(_ track: TrackInfo) async throws {
        await musicService.setVolume(level: settings.volumeSettings.normalVolume)
        updateState { $0.volume = settings.volumeSettings.normalVolume }
        try await musicService.play(track: track)
        trackStartedAt = ContinuousClock.now
    }

    private func playStandaloneNarration(wavData: Data) async throws {
        try await waitWhilePaused()
        try await audioPlaybackService.play(wavData: wavData)
    }

    private func synthesizeNarration(dialogues: [DialogueLine], segmentLabel: String) async throws -> Data {
        updateState { $0.statusMessage = "TTS音声作成開始（\(segmentLabel)）" }
        do {
            let result = try await ttsService.synthesize(dialogues: dialogues, settings: settings)
            let isFallback = result.modelUsed != settings.geminiTTSModel
            if isFallback {
                updateState { $0.statusMessage = "TTS音声作成終了（副モデル: \(result.modelUsed)）" }
            } else {
                updateState { $0.statusMessage = "TTS音声作成終了" }
            }
            return result.wavData
        } catch {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "\(segmentLabel) の音声生成に失敗しました: \(error.localizedDescription)"]
            )
        }
    }

    private func playNarrationWithMusicLead(wavData: Data, track: TrackInfo) async throws {
        let durationSeconds = wavDurationSeconds(wavData)
        let startDelay = max(0, durationSeconds - settings.volumeSettings.musicLeadSeconds)

        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        async let startTask: Void = startTrackAfterDelay(track: track, delaySeconds: startDelay)
        _ = try await (narrationTask, startTask)
        await musicService.setVolume(level: settings.volumeSettings.normalVolume)
    }

    private func playTransition(wavData: Data, nextTrack: TrackInfo) async throws {
        let durationSeconds = wavDurationSeconds(wavData)
        let startDelay = max(0, durationSeconds - settings.volumeSettings.musicLeadSeconds)

        async let narrationTask: Void = audioPlaybackService.play(wavData: wavData)
        async let startTask: Void = startTrackAfterDelay(track: nextTrack, delaySeconds: startDelay, startVolume: settings.volumeSettings.talkVolume)
        _ = try await (narrationTask, startTask)
        await fadeMusicVolume(targetVolume: settings.volumeSettings.normalVolume, durationSeconds: settings.volumeSettings.fadeDuration)
    }

    private func startTrackAfterDelay(track: TrackInfo, delaySeconds: Double, startVolume: Int? = nil) async throws {
        try await waitRespectingPause(seconds: delaySeconds)
        if let startVolume {
            await musicService.setVolume(level: startVolume)
        }
        try await musicService.play(track: track)
        trackStartedAt = ContinuousClock.now
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

    /// 曲の実再生開始時刻を基準に、トランジション開始まで待機すべき秒数を計算する。
    /// maxPlaybackDurationSeconds が 0 より大きい場合は、曲の再生時間をそこで打ち切る。
    private func calculateWaitBeforeTransition(trackDurationSeconds: Int, fadeEarlySeconds: Int) -> Double {
        var effectiveDuration = Double(trackDurationSeconds)
        let maxPlayback = Double(settings.volumeSettings.maxPlaybackDurationSeconds)
        if maxPlayback > 0 {
            effectiveDuration = min(effectiveDuration, maxPlayback)
        }
        guard let startedAt = trackStartedAt else {
            return max(0, effectiveDuration - Double(fadeEarlySeconds))
        }
        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, effectiveDuration - Double(fadeEarlySeconds) - elapsedSeconds)
    }

    private func wavDurationSeconds(_ wavData: Data) -> Double {
        guard wavData.count > 44 else {
            return 0
        }
        let pcmBytes = wavData.count - 44
        let bytesPerSecond = 24_000 * 2
        return Double(pcmBytes) / Double(bytesPerSecond)
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
        }
    }
}
