import Foundation

/// Drives the radio playback lifecycle.
actor RadioOrchestrator {
    private struct PreparedNarration: Sendable {
        let script: RadioScript
        let wavData: Data
        let segmentLabel: String
        let cueSheetIndentLevel: Int
    }

    private struct ActiveNarration: Sendable {
        let prepared: PreparedNarration
        let playbackTask: Task<Void, Error>
        let durationSeconds: Double
    }

    private struct NarrationAudioPolicy: Sendable {
        let allowsBedAudio: Bool
        let jinglePlacement: JinglePlacement?
    }

    private struct ResolvedNarration: Sendable {
        let prepared: PreparedNarration
        let didTrackReachNaturalEnd: Bool
    }

    private enum NarrationWaitOutcome {
        case narrationReady
        case naturalTrackEnd
    }

    // MARK: - 事前生成モード用キャッシュ

    /// 事前生成した台本のキャッシュキー。
    private enum SegmentKey: Hashable, Sendable {
        case opening
        case transition(fromIndex: Int)
        case closing

        var persistableKey: String {
            switch self {
            case .opening:
                return "opening"
            case .transition(let fromIndex):
                return "transition_\(fromIndex)"
            case .closing:
                return "closing"
            }
        }

        init?(persistableKey: String) {
            switch persistableKey {
            case "opening":
                self = .opening
            case "closing":
                self = .closing
            default:
                let prefix = "transition_"
                guard persistableKey.hasPrefix(prefix),
                      let fromIndex = Int(persistableKey.dropFirst(prefix.count)) else {
                    return nil
                }
                self = .transition(fromIndex: fromIndex)
            }
        }
    }

    /// 事前生成した台本と確定済み TTS 設定の組。
    private struct CachedSegment: Sendable {
        var script: RadioScript
        var narrationSettings: AppSettings
    }

    // MARK: - 依存

    private let settings: AppSettings
    private let musicService: any MusicService
    private let musicPlaybackProfile: MusicPlaybackProfile
    private let scriptService: any ScriptGenerationService
    private let ttsService: any TTSService
    private let audioPlaybackService: any AudioPlaybackServiceProtocol
    private let bedAudioPlaybackService: any BedAudioPlaybackServiceProtocol
    private let recordingService: (any ShowRecordingServiceProtocol)?
    private let cueSheetLogger: ShowCueSheetLogger?
    private let scriptStore: (any PreGeneratedScriptStoreProtocol)?
    private let currentDateProvider: @Sendable () -> Date
    private let stateDidChange: @Sendable (RadioState) -> Void
    /// 事前生成モードでレビュー対象の台本が揃った時に呼ばれるコールバック。
    private let reviewDidBecomeAvailable: (@Sendable ([ReviewScriptItem]) -> Void)?
    /// 保存済み事前生成台本の再利用確認が必要になった時に呼ばれるコールバック。
    private let reusePromptDidBecomeAvailable: (@Sendable () -> Void)?

    // MARK: - 可変状態

    private var radioState = RadioState()
    private var playbackTask: Task<Void, Never>?
    private var isStopRequested = false
    private var artistTopicHistory: [String: [String]] = [:]
    private var albumTopicHistory: [String: [String]] = [:]
    private var sessionTopicLedger: [String] = []
    private var positionPollingTask: Task<Void, Never>?
    /// 曲の実再生開始時刻（再生位置が取れない場合のフォールバック用）
    private var trackStartedAt: ContinuousClock.Instant?
    private let maxSessionTopicLedgerEntries = 8
    /// 事前生成済み台本のキャッシュ。キャッシュが空のときは従来のオンデマンド生成。
    private var preGeneratedSegments: [SegmentKey: CachedSegment] = [:]
    /// レビュー中断用の continuation。
    private var reviewContinuation: CheckedContinuation<[ReviewScriptItem], Error>?
    /// 再利用確認中断用の continuation。
    private var reuseContinuation: CheckedContinuation<Bool, Error>?

    /// バックエンドの自動連続再生を抑止するため、曲の自然終了より手前で停止する安全マージン（秒）。
    /// これにより orchestrator が明示的に stop を呼ぶ前にバックエンドが次曲へ進むレースを防ぐ。
    private let naturalEndSafetyMarginSeconds: Double = 1.0

    init(
        settings: AppSettings,
        musicService: any MusicService,
        musicPlaybackProfile: MusicPlaybackProfile,
        scriptService: any ScriptGenerationService,
        ttsService: any TTSService,
        audioPlaybackService: any AudioPlaybackServiceProtocol,
        bedAudioPlaybackService: any BedAudioPlaybackServiceProtocol,
        recordingService: (any ShowRecordingServiceProtocol)? = nil,
        cueSheetLogger: ShowCueSheetLogger? = nil,
        scriptStore: (any PreGeneratedScriptStoreProtocol)? = nil,
        currentDateProvider: @escaping @Sendable () -> Date = { Date() },
        reviewDidBecomeAvailable: (@Sendable ([ReviewScriptItem]) -> Void)? = nil,
        reusePromptDidBecomeAvailable: (@Sendable () -> Void)? = nil,
        stateDidChange: @escaping @Sendable (RadioState) -> Void
    ) {
        self.settings = settings
        self.musicService = musicService
        self.musicPlaybackProfile = musicPlaybackProfile
        self.scriptService = scriptService
        self.ttsService = ttsService
        self.audioPlaybackService = audioPlaybackService
        self.bedAudioPlaybackService = bedAudioPlaybackService
        self.recordingService = recordingService
        self.cueSheetLogger = cueSheetLogger
        self.scriptStore = scriptStore
        self.currentDateProvider = currentDateProvider
        self.reviewDidBecomeAvailable = reviewDidBecomeAvailable
        self.reusePromptDidBecomeAvailable = reusePromptDidBecomeAvailable
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
        await bedAudioPlaybackService.pausePlayback()
    }

    func resumeShow() async {
        guard radioState.isRunning, radioState.isPaused else {
            return
        }
        updateState { $0.isPaused = false }
        await musicService.resumePlayback()
        await audioPlaybackService.resumePlayback()
        await bedAudioPlaybackService.resumePlayback()
    }

    func stopShow() async {
        isStopRequested = true
        failPendingContinuations()
        playbackTask?.cancel()
        playbackTask = nil
        stopPositionPolling()
        trackStartedAt = nil
        await bedAudioPlaybackService.stopPlayback()
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
            if settings.defaultScriptGenerationMode == .preGenerate, !isStopRequested {
                await scriptStore?.clear()
            }
            await finishRunShow(errorMessage: nil)
        } catch is CancellationError {
            await finishRunShow(errorMessage: nil)
        } catch {
            await finishRunShow(errorMessage: error.localizedDescription)
        }
    }

    private func performShow(playlistName: String, initialTracks: [TrackInfo]? = nil) async throws {
        let tracks = try await loadTracks(for: playlistName, initialTracks: initialTracks)
        await cueSheetLogger?.append(
            "再生セッション開始(プレイリスト: \(playlistName) / 曲数: \(tracks.count))",
            indentLevel: 0
        )

        // 事前生成モード: 保存済み台本の確認 → 必要に応じて生成 → レビュー → 承認後に保存
        if settings.defaultScriptGenerationMode == .preGenerate {
            let trackFingerprint = makeTrackFingerprint(tracks)
            var didRestoreSession = false
            if let savedSession = await scriptStore?.load(),
               savedSession.playlistName == playlistName,
               savedSession.trackFingerprint == trackFingerprint {
                if try await awaitReuseDecision() {
                    restorePreGeneratedSegments(from: savedSession)
                    didRestoreSession = true
                    await cueSheetLogger?.append("事前生成: 保存済み台本を復元", indentLevel: 0)
                } else {
                    await scriptStore?.clear()
                    await cueSheetLogger?.append("事前生成: 保存済み台本を退避して再生成", indentLevel: 0)
                }
            }
            if !didRestoreSession {
                try await preGenerateAllScripts(tracks: tracks)
            }
            let editedItems = try await awaitScriptReview()
            applyEditedSegments(editedItems)
            await scriptStore?.save(makePersistedSession(playlistName: playlistName, tracks: tracks))
        }

        let openingNarration = try await prepareOpeningNarration(tracks: tracks)
        rememberTopics(for: tracks[0], script: openingNarration.script)

        await startRecordingIfNeeded(playlistName: playlistName)

        var activeNarration = await startNarration(
            openingNarration,
            audioPolicy: openingNarrationAudioPolicy()
        )

        for (indexValue, track) in tracks.enumerated() {
            try Task.checkCancellation()
            if isStopRequested {
                return
            }

            await cueSheetLogger?.append(
                "次曲(\(indexValue + 1)/\(tracks.count) \(trackCueLabel(track)))",
                indentLevel: 0
            )
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
                completedTracks: completedTracks,
                trackIndex: indexValue
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
            await cueSheetLogger?.append("再生セッション終了(エラー: \(errorMessage))", indentLevel: 0)
        } else {
            await cueSheetLogger?.append("再生セッション終了", indentLevel: 0)
        }
        if let errorMessage {
            updateState { $0.errorMessage = errorMessage }
        }
        await bedAudioPlaybackService.stopPlayback()
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
        let filename = "\(timestamp)_\(safeName).wav"
        let outputURL = baseDir.appendingPathComponent(filename)
        updateState { $0.recordingOutputURL = outputURL }
        return outputURL
    }

    private func prepareOpeningNarration(tracks: [TrackInfo]) async throws -> PreparedNarration {
        let segmentLabel = String(localized: "オープニング")
        await cueSheetLogger?.append(
            "\(segmentLabel)(\(trackCueLabel(tracks.first)))",
            indentLevel: 0
        )
        return try await CueSheetLogContext.$currentIndentLevel.withValue(1) {
            let cached = preGeneratedSegments[.opening]
            let narrationSettings = cached?.narrationSettings ?? makeDirectionAdjustedSettings()
            let script: RadioScript
            if let cached {
                script = cached.script
                updateState { $0.statusMessage = String(localized: "キャッシュ済み台本を使用（オープニング）"); $0.isProcessing = false }
                await cueSheetLogger?.append("キャッシュ済み台本を使用(\(segmentLabel))")
            } else {
                updateState { $0.statusMessage = String(localized: "スクリプト作成開始（オープニング）"); $0.isProcessing = true }
                await cueSheetLogger?.append("スクリプト作成開始(\(segmentLabel))")
                script = try await scriptService.generateOpening(tracks: tracks, settings: narrationSettings)
                updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
                await cueSheetLogger?.append(
                    "スクリプト作成終了(\(segmentLabel) / 発話: \(script.dialogues.count) / 要約: \(script.summaryBullets.count))"
                )
            }
            let wavData = try await synthesizeNarration(
                dialogues: script.dialogues,
                segmentLabel: segmentLabel,
                settings: narrationSettings
            )
            return PreparedNarration(
                script: script,
                wavData: wavData,
                segmentLabel: segmentLabel,
                cueSheetIndentLevel: 1
            )
        }
    }

    private func makeNextNarrationTask(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo?,
        completedTracks: [TrackInfo],
        trackIndex: Int
    ) -> Task<PreparedNarration, Error> {
        Task {
            if let nextTrack {
                return try await generatePreparedTransitionNarration(
                    currentTrack: currentTrack,
                    nextTrack: nextTrack,
                    trackIndex: trackIndex
                )
            }
            return try await generatePreparedClosingNarration(tracks: completedTracks)
        }
    }

    private func generatePreparedTransitionNarration(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        trackIndex: Int
    ) async throws -> PreparedNarration {
        let segmentLabel = String(format: String(localized: "%@ から %@ へのトランジション"), currentTrack.name, nextTrack.name)
        await cueSheetLogger?.append(
            "トランジション(\(trackShortLabel(currentTrack)) → \(trackShortLabel(nextTrack)))",
            indentLevel: 0
        )
        return try await CueSheetLogContext.$currentIndentLevel.withValue(1) {
            let cached = preGeneratedSegments[.transition(fromIndex: trackIndex)]
            let narrationSettings = cached?.narrationSettings ?? makeDirectionAdjustedSettings()
            let script: RadioScript
            if let cached {
                script = cached.script
                updateState {
                    $0.statusMessage = String(format: String(localized: "キャッシュ済み台本を使用（%@ → %@）"), currentTrack.name, nextTrack.name)
                    $0.isProcessing = false
                }
                await cueSheetLogger?.append("キャッシュ済み台本を使用(\(segmentLabel))")
            } else {
                let continuityNote = buildContinuityNote(for: nextTrack, previousTrack: currentTrack)
                updateState {
                    $0.statusMessage = String(format: String(localized: "スクリプト作成開始（%@ → %@）"), currentTrack.name, nextTrack.name)
                    $0.isProcessing = true
                }
                await cueSheetLogger?.append("スクリプト作成開始(\(segmentLabel))")
                script = try await scriptService.generateTransition(
                    currentTrack: currentTrack,
                    nextTrack: nextTrack,
                    settings: narrationSettings,
                    continuityNote: continuityNote
                )
                updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
                await cueSheetLogger?.append(
                    "スクリプト作成終了(\(segmentLabel) / 発話: \(script.dialogues.count) / 要約: \(script.summaryBullets.count))"
                )
            }
            let wavData = try await synthesizeNarration(
                dialogues: script.dialogues,
                segmentLabel: segmentLabel,
                settings: narrationSettings
            )
            return PreparedNarration(
                script: script,
                wavData: wavData,
                segmentLabel: segmentLabel,
                cueSheetIndentLevel: 1
            )
        }
    }

    private func generatePreparedClosingNarration(tracks: [TrackInfo]) async throws -> PreparedNarration {
        let segmentLabel = String(localized: "クロージング")
        await cueSheetLogger?.append("\(segmentLabel)", indentLevel: 0)
        return try await CueSheetLogContext.$currentIndentLevel.withValue(1) {
            let cached = preGeneratedSegments[.closing]
            let narrationSettings = cached?.narrationSettings ?? makeDirectionAdjustedSettings()
            let script: RadioScript
            if let cached {
                script = cached.script
                updateState { $0.statusMessage = String(localized: "キャッシュ済み台本を使用（クロージング）"); $0.isProcessing = false }
                await cueSheetLogger?.append("キャッシュ済み台本を使用(\(segmentLabel))")
            } else {
                updateState { $0.statusMessage = String(localized: "スクリプト作成開始（クロージング）"); $0.isProcessing = true }
                await cueSheetLogger?.append("スクリプト作成開始(\(segmentLabel))")
                script = try await scriptService.generateClosing(tracks: tracks, settings: narrationSettings)
                updateState { $0.statusMessage = String(localized: "スクリプト作成終了"); $0.isProcessing = false }
                await cueSheetLogger?.append(
                    "スクリプト作成終了(\(segmentLabel) / 発話: \(script.dialogues.count) / 要約: \(script.summaryBullets.count))"
                )
            }
            let wavData = try await synthesizeNarration(
                dialogues: script.dialogues,
                segmentLabel: segmentLabel,
                settings: narrationSettings
            )
            return PreparedNarration(
                script: script,
                wavData: wavData,
                segmentLabel: segmentLabel,
                cueSheetIndentLevel: 1
            )
        }
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
        await cueSheetLogger?.append(
            "曲選択(\(radioState.trackIndex + 1)/\(max(1, radioState.playlistTrackCount)) \(trackCueLabel(track)))",
            indentLevel: 1
        )
        let leadSeconds = effectiveMusicLeadSeconds()
        if settings.defaultOverlapMode == .enabled, leadSeconds > 0 {
            try await waitUntilNarrationRemainingSeconds(
                activeNarration,
                isAtMost: leadSeconds
            )
            await bedAudioPlaybackService.fadeOutAndStopBed(settings: settings.bgmSettings)
            try await startTrack(track, startVolume: settings.volumeSettings.talkVolume)
            try await activeNarration.playbackTask.value
            await fadeMusicVolume(
                targetVolume: settings.volumeSettings.normalVolume,
                durationSeconds: settings.volumeSettings.fadeDuration,
                eventLabel: String(localized: "フェードイン"),
                indentLevel: 2
            )
        } else {
            try await activeNarration.playbackTask.value
            await bedAudioPlaybackService.fadeOutAndStopBed(settings: settings.bgmSettings)
            try await startTrack(track, startVolume: settings.volumeSettings.normalVolume)
        }
    }

    private func openingNarrationAudioPolicy() -> NarrationAudioPolicy {
        NarrationAudioPolicy(
            allowsBedAudio: true,
            jinglePlacement: settings.bgmSettings.isOpeningJingleEnabled ? .opening : nil
        )
    }

    private func startNarration(
        _ prepared: PreparedNarration,
        audioPolicy: NarrationAudioPolicy
    ) async -> ActiveNarration {
        let estimatedJingleDuration: Double
        if let jinglePlacement = audioPolicy.jinglePlacement {
            estimatedJingleDuration = await bedAudioPlaybackService.estimateJingleDuration(
                settings: settings.bgmSettings,
                placement: jinglePlacement
            )
        } else {
            estimatedJingleDuration = 0
        }

        let playbackTask = Task {
            try await self.waitWhilePaused()
            if let jinglePlacement = audioPolicy.jinglePlacement {
                let jingleDuration = await self.bedAudioPlaybackService.playJingle(
                    settings: self.settings.bgmSettings,
                    placement: jinglePlacement
                )
                if jingleDuration > 0 {
                    await self.cueSheetLogger?.append(
                        "ジングル再生(\(prepared.segmentLabel) / \(String(format: "%.2f", jingleDuration))s)",
                        indentLevel: prepared.cueSheetIndentLevel
                    )
                }
                try await self.waitWhilePaused()
            }

            if audioPolicy.allowsBedAudio {
                await self.bedAudioPlaybackService.startBed(settings: self.settings.bgmSettings)
            }
            await self.cueSheetLogger?.append(
                "TTS再生開始(\(prepared.segmentLabel))",
                indentLevel: prepared.cueSheetIndentLevel
            )
            do {
                try await self.audioPlaybackService.play(wavData: prepared.wavData)
                await self.cueSheetLogger?.append(
                    "TTS再生終了(\(prepared.segmentLabel))",
                    indentLevel: prepared.cueSheetIndentLevel
                )
                if audioPolicy.allowsBedAudio {
                    await self.bedAudioPlaybackService.fadeOutAndStopBed(settings: self.settings.bgmSettings)
                }
            } catch {
                await self.bedAudioPlaybackService.stopPlayback()
                await self.cueSheetLogger?.append(
                    "TTS再生終了(\(prepared.segmentLabel) / エラー: \(error.localizedDescription))",
                    indentLevel: prepared.cueSheetIndentLevel
                )
                throw error
            }
        }
        return ActiveNarration(
            prepared: prepared,
            playbackTask: playbackTask,
            durationSeconds: wavDurationSeconds(prepared.wavData) + estimatedJingleDuration
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
        max(0, settings.volumeSettings.musicLeadSeconds + musicPlaybackProfile.startupLatencyCompensationSeconds)
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

        if isClosingNarration, settings.bgmSettings.isClosingJingleEnabled {
            if !resolvedNarration.didTrackReachNaturalEnd {
                let fadeDuration = calculateFadeOutDuration()
                await fadeOutAndStopTrack(durationSeconds: fadeDuration)
            }
            return await startNarration(
                resolvedNarration.prepared,
                audioPolicy: NarrationAudioPolicy(allowsBedAudio: true, jinglePlacement: .closing)
            )
        }

        if settings.defaultOverlapMode == .enabled, !resolvedNarration.didTrackReachNaturalEnd {
            await fadeMusicVolume(
                targetVolume: settings.volumeSettings.talkVolume,
                durationSeconds: settings.volumeSettings.fadeDuration,
                eventLabel: String(localized: "ダッキング"),
                indentLevel: 1
            )
            let activeNarration = await startNarration(
                resolvedNarration.prepared,
                audioPolicy: NarrationAudioPolicy(allowsBedAudio: false, jinglePlacement: nil)
            )
            let fadeDuration = calculateFadeOutDuration()
            await fadeOutAndStopTrack(durationSeconds: fadeDuration)
            await startBedForRemainingNarrationIfNeeded(activeNarration)
            return activeNarration
        }

        await stopTrackImmediately()
        return await startNarration(
            resolvedNarration.prepared,
            audioPolicy: NarrationAudioPolicy(allowsBedAudio: true, jinglePlacement: nil)
        )
    }

    private func startBedForRemainingNarrationIfNeeded(_ activeNarration: ActiveNarration) async {
        guard settings.bgmSettings.isBedEnabled,
              await audioPlaybackService.fetchIsPlaying() else {
            return
        }

        await bedAudioPlaybackService.startBed(settings: settings.bgmSettings)
        Task { [settings, bedAudioPlaybackService] in
            do {
                try await activeNarration.playbackTask.value
                await bedAudioPlaybackService.fadeOutAndStopBed(settings: settings.bgmSettings)
            } catch {
                await bedAudioPlaybackService.stopPlayback()
            }
        }
    }

    private func setMusicVolume(level: Int) async {
        await musicService.setVolume(level: level)
        updateState { $0.volume = level }
    }

    private func startTrack(_ track: TrackInfo, startVolume: Int) async throws {
        await cueSheetLogger?.append("音量設定(\(startVolume)%)", indentLevel: 2)
        await setMusicVolume(level: startVolume)
        try await musicService.play(track: track)
        await setMusicVolume(level: startVolume)
        await cueSheetLogger?.append("曲再生開始(\(trackCueLabel(track)))", indentLevel: 2)
        trackStartedAt = ContinuousClock.now
        startPositionPolling(track: track)
    }

    private func stopTrackImmediately() async {
        stopPositionPolling()
        trackStartedAt = nil
        await musicService.stopPlayback()
        if let currentTrack = radioState.currentTrack {
            await cueSheetLogger?.append("曲再生終了(\(trackCueLabel(currentTrack)))", indentLevel: 1)
        }
        updateState { $0.currentPlaybackPosition = 0 }
    }

    private func synthesizeNarration(
        dialogues: [DialogueLine],
        segmentLabel: String,
        settings narrationSettings: AppSettings
    ) async throws -> Data {
        updateState { $0.statusMessage = String(format: String(localized: "TTS音声作成開始（%@）"), segmentLabel); $0.isProcessing = true }
        await cueSheetLogger?.append("TTS音声作成開始(\(segmentLabel))")
        do {
            let result = try await ttsService.synthesize(dialogues: dialogues, settings: narrationSettings)
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
            await cueSheetLogger?.append(
                "TTS音声作成終了(\(segmentLabel) / セット: \(credentialLabel) / モデル: \(result.modelUsed) / フォールバック: \(result.didUseFallback ? "あり" : "なし"))"
            )
            return result.wavData
        } catch {
            await cueSheetLogger?.append("TTS音声作成終了(\(segmentLabel) / エラー: \(error.localizedDescription))")
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "%@ の音声生成に失敗しました: %@"), segmentLabel, error.localizedDescription)]
            )
        }
    }

    private func makeDirectionAdjustedSettings() -> AppSettings {
        TimeBasedDirectionResolver.makeSettings(
            settings: settings,
            date: currentDateProvider()
        )
    }

    /// 音楽サービスから取得した実際の再生位置がアウトロ開始位置に達するまでポーリング待機
    private func waitUntilOutroPoint(track: TrackInfo) async throws {
        let effectiveDuration = effectivePlaybackDuration(trackDurationSeconds: track.durationSeconds)
        // fadeEarlySeconds による早めカットオフに加え、曲が十分長い場合のみ
        // naturalEndSafetyMarginSeconds 分の下限ガードを適用してバックエンドの自動連続再生を抑止する。
        let fadeTarget = effectiveDuration - Double(settings.volumeSettings.fadeEarlySeconds)
        let safetyTarget = effectiveDuration > naturalEndSafetyMarginSeconds * 2
            ? effectiveDuration - naturalEndSafetyMarginSeconds
            : fadeTarget
        let targetPosition = max(0, min(fadeTarget, safetyTarget))

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
        // バックエンドの自動連続再生を抑止するため、曲が十分長い場合のみ自然終了より手前で停止する。
        // 曲の長さが安全マージンの2倍未満（短い曲）は元の挙動を保持し、
        // それ以外は naturalEndSafetyMarginSeconds 分手前を目標にする。
        let targetPosition: Double
        if naturalDuration > naturalEndSafetyMarginSeconds * 2 {
            targetPosition = naturalDuration - naturalEndSafetyMarginSeconds
        } else {
            targetPosition = naturalDuration
        }

        while !isStopRequested {
            try Task.checkCancellation()
            if await hasReachedPlaybackPosition(targetPosition) {
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
            await fadeMusicVolume(
                targetVolume: 0,
                durationSeconds: durationSeconds,
                eventLabel: String(localized: "フェードアウト"),
                indentLevel: 1
            )
        }
        trackStartedAt = nil
        await musicService.stopPlayback()
        if let currentTrack = radioState.currentTrack {
            await cueSheetLogger?.append("曲再生終了(\(trackCueLabel(currentTrack)))", indentLevel: 1)
        }
        updateState { $0.currentPlaybackPosition = 0 }
    }

    private func fadeMusicVolume(
        targetVolume: Int,
        durationSeconds: Double,
        eventLabel: String,
        indentLevel: Int
    ) async {
        let currentVolume = await musicService.fetchVolume()
        guard currentVolume != targetVolume else {
            return
        }
        await cueSheetLogger?.append(
            "\(eventLabel)開始(\(currentVolume)% → \(targetVolume)% / \(String(format: "%.2f", durationSeconds))s)",
            indentLevel: indentLevel
        )

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
        await cueSheetLogger?.append("\(eventLabel)終了(\(targetVolume)%)", indentLevel: indentLevel)
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

        let sessionSummaryEntries = sessionTopicSummaryEntries(for: track, script: script)
        for summaryEntry in sessionSummaryEntries {
            appendSessionTopicSummary(summaryEntry)
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
                newEntries.forEach {
                    lines.append("- \($0)")
                    shownEntries.insert($0)
                }
            }
        }

        let sessionEntries = sessionTopicLedger.filter { !shownEntries.contains($0) }
        if !sessionEntries.isEmpty {
            lines.append("番組内で既に触れた話題（重複回避）:")
            sessionEntries.forEach { lines.append("- \($0)") }
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

    private func appendSessionTopicSummary(_ summary: String) {
        guard !summary.isEmpty, !sessionTopicLedger.contains(summary) else {
            return
        }
        sessionTopicLedger.append(summary)
        if sessionTopicLedger.count > maxSessionTopicLedgerEntries {
            sessionTopicLedger = Array(sessionTopicLedger.suffix(maxSessionTopicLedgerEntries))
        }
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

    private func sessionTopicSummaryEntries(for track: TrackInfo, script: RadioScript) -> [String] {
        script.summaryBullets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "\(track.name): \($0)" }
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

    // MARK: - 事前生成モード

    /// 全セグメントの台本を逐次生成し `preGeneratedSegments` にキャッシュする（TTSなし）。
    private func preGenerateAllScripts(tracks: [TrackInfo]) async throws {
        preGeneratedSegments = [:]

        // オープニング
        let openingSettings = makeDirectionAdjustedSettings()
        updateState { $0.statusMessage = String(localized: "台本一括生成中（オープニング）"); $0.isProcessing = true }
        await cueSheetLogger?.append("事前生成: オープニング台本作成開始", indentLevel: 0)
        let openingScript = try await scriptService.generateOpening(tracks: tracks, settings: openingSettings)
        await cueSheetLogger?.append("事前生成: オープニング台本作成終了(発話: \(openingScript.dialogues.count) / 要約: \(openingScript.summaryBullets.count))", indentLevel: 0)
        rememberTopics(for: tracks[0], script: openingScript)
        preGeneratedSegments[.opening] = CachedSegment(script: openingScript, narrationSettings: openingSettings)

        // 各トランジション + クロージング
        for index in 0..<tracks.count {
            try Task.checkCancellation()
            if isStopRequested { throw CancellationError() }

            let current = tracks[index]
            let next = index + 1 < tracks.count ? tracks[index + 1] : nil
            let segmentSettings = makeDirectionAdjustedSettings()

            if let next {
                let continuityNote = buildContinuityNote(for: next, previousTrack: current)
                updateState {
                    $0.statusMessage = String(format: String(localized: "台本一括生成中（%@ → %@）"), current.name, next.name)
                    $0.isProcessing = true
                }
                await cueSheetLogger?.append("事前生成: トランジション台本作成開始(\(trackShortLabel(current)) → \(trackShortLabel(next)))", indentLevel: 0)
                let script = try await scriptService.generateTransition(
                    currentTrack: current,
                    nextTrack: next,
                    settings: segmentSettings,
                    continuityNote: continuityNote
                )
                await cueSheetLogger?.append("事前生成: トランジション台本作成終了(発話: \(script.dialogues.count) / 要約: \(script.summaryBullets.count))", indentLevel: 0)
                rememberTopics(for: next, script: script)
                preGeneratedSegments[.transition(fromIndex: index)] = CachedSegment(script: script, narrationSettings: segmentSettings)
            } else {
                let completedTracks = Array(tracks.prefix(index + 1))
                updateState { $0.statusMessage = String(localized: "台本一括生成中（クロージング）"); $0.isProcessing = true }
                await cueSheetLogger?.append("事前生成: クロージング台本作成開始", indentLevel: 0)
                let script = try await scriptService.generateClosing(tracks: completedTracks, settings: segmentSettings)
                await cueSheetLogger?.append("事前生成: クロージング台本作成終了(発話: \(script.dialogues.count) / 要約: \(script.summaryBullets.count))", indentLevel: 0)
                preGeneratedSegments[.closing] = CachedSegment(script: script, narrationSettings: segmentSettings)
            }
        }

        // 再生ループ内の rememberTopics で二重蓄積しないようリセット
        artistTopicHistory = [:]
        albumTopicHistory = [:]
        sessionTopicLedger = []

        updateState { $0.statusMessage = String(localized: "台本一括生成完了"); $0.isProcessing = false }
        await cueSheetLogger?.append("事前生成: 全台本生成完了(\(preGeneratedSegments.count) セグメント)", indentLevel: 0)
    }

    /// 保存済み台本の再利用判断を UI に通知し、選択されるまで中断する。
    private func awaitReuseDecision() async throws -> Bool {
        updateState {
            $0.phase = .reviewing
            $0.statusMessage = String(localized: "保存済み台本の再利用確認待ち")
            $0.isProcessing = false
        }
        reusePromptDidBecomeAvailable?()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isStopRequested {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.reuseContinuation = continuation
            }
        } onCancel: {
            Task { await self.failReuseIfPending() }
        }
    }

    /// レビュー対象の台本一覧を UI に通知し、承認されるまで中断する。
    private func awaitScriptReview() async throws -> [ReviewScriptItem] {
        let sortedKeys = sortedPreGeneratedSegmentKeys()

        let reviewItems: [ReviewScriptItem] = sortedKeys.enumerated().map { (itemIndex, key) in
            let segment = preGeneratedSegments[key]!
            let label: String = {
                switch key {
                case .opening: return String(localized: "オープニング")
                case .transition(let fromIndex): return String(format: String(localized: "トランジション %d"), fromIndex + 1)
                case .closing: return String(localized: "クロージング")
                }
            }()
            return ReviewScriptItem(
                id: itemIndex,
                segmentLabel: label,
                script: segment.script,
                sceneDirection: segment.narrationSettings.directionSettings.sceneDirection,
                maleVoiceName: segment.narrationSettings.voiceSettings.maleVoiceName,
                femaleVoiceName: segment.narrationSettings.voiceSettings.femaleVoiceName
            )
        }

        updateState {
            $0.phase = .reviewing
            $0.statusMessage = String(localized: "台本のレビュー待ち")
            $0.isProcessing = false
        }
        reviewDidBecomeAvailable?(reviewItems)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isStopRequested {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.reviewContinuation = continuation
            }
        } onCancel: {
            Task { await self.failReviewIfPending() }
        }
    }

    /// 編集済み `ReviewScriptItem` のデータを `preGeneratedSegments` へ反映する。
    private func applyEditedSegments(_ editedItems: [ReviewScriptItem]) {
        let sortedKeys = sortedPreGeneratedSegmentKeys()

        for (itemIndex, key) in sortedKeys.enumerated() {
            guard itemIndex < editedItems.count else { break }
            let edited = editedItems[itemIndex]
            preGeneratedSegments[key]?.script = edited.script
            preGeneratedSegments[key]?.narrationSettings.directionSettings.sceneDirection = edited.sceneDirection
        }
    }

    /// 保存済み台本セッションをメモリキャッシュへ復元する。
    private func restorePreGeneratedSegments(from session: PersistedScriptSession) {
        preGeneratedSegments = Dictionary(
            uniqueKeysWithValues: session.segments.compactMap { segment in
                guard let key = SegmentKey(persistableKey: segment.key) else {
                    return nil
                }
                return (key, CachedSegment(
                    script: segment.script,
                    narrationSettings: segment.narrationSettings.applyingRuntimeSecrets(from: settings)
                ))
            }
        )
    }

    /// 現在の事前生成キャッシュからディスク保存用セッションを作る。
    private func makePersistedSession(playlistName: String, tracks: [TrackInfo]) -> PersistedScriptSession {
        let segments = sortedPreGeneratedSegmentKeys().compactMap { key -> PersistedSegment? in
            guard let segment = preGeneratedSegments[key] else {
                return nil
            }
            return PersistedSegment(
                key: key.persistableKey,
                script: segment.script,
                narrationSettings: segment.narrationSettings.strippingSecrets()
            )
        }
        return PersistedScriptSession(
            playlistName: playlistName,
            trackFingerprint: makeTrackFingerprint(tracks),
            tracks: tracks,
            segments: segments,
            savedAt: currentDateProvider()
        )
    }

    private func makeTrackFingerprint(_ tracks: [TrackInfo]) -> String {
        tracks.map(\.id).joined(separator: "\n")
    }

    private func sortedPreGeneratedSegmentKeys() -> [SegmentKey] {
        var keys = Array(preGeneratedSegments.keys)
        keys.sort { lhs, rhs in
            orderSegmentKey(lhs) < orderSegmentKey(rhs)
        }
        return keys
    }

    private func orderSegmentKey(_ key: SegmentKey) -> Int {
        switch key {
        case .opening: return 0
        case .transition(let i): return 1 + i
        case .closing: return Int.max
        }
    }

    /// 保存済み台本の再利用を承認して処理を続行する。
    func confirmReuse() {
        guard let continuation = reuseContinuation else { return }
        reuseContinuation = nil
        continuation.resume(returning: true)
    }

    /// 保存済み台本を再利用対象から外し、台本を作り直す。
    func declineReuse() {
        guard let continuation = reuseContinuation else { return }
        reuseContinuation = nil
        continuation.resume(returning: false)
    }

    /// レビュー結果を承認して再生を続行する。
    func approveScripts(_ editedItems: [ReviewScriptItem]) {
        guard let continuation = reviewContinuation else { return }
        reviewContinuation = nil
        continuation.resume(returning: editedItems)
    }

    /// レビューをキャンセルして番組を停止する。
    func cancelReview() async {
        if let continuation = reviewContinuation {
            reviewContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        await stopShow()
    }

    /// 中断中のレビュー continuation を CancellationError で失敗させる（リーク防止）。
    private func failReviewIfPending() {
        guard let continuation = reviewContinuation else { return }
        reviewContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    /// 中断中の再利用確認 continuation を CancellationError で失敗させる（リーク防止）。
    private func failReuseIfPending() {
        guard let continuation = reuseContinuation else { return }
        reuseContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    /// 中断中の continuation をすべて解放する（リーク防止）。
    private func failPendingContinuations() {
        failReviewIfPending()
        failReuseIfPending()
    }

    private func resetState() {
        trackStartedAt = nil
        preGeneratedSegments = [:]
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

    private func trackCueLabel(_ track: TrackInfo?) -> String {
        guard let track else {
            return String(localized: "不明な曲")
        }
        return "\(track.name) / \(track.artist) / \(track.album)"
    }

    private func trackShortLabel(_ track: TrackInfo) -> String {
        "\(track.name) / \(track.artist)"
    }
}
