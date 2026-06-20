import XCTest
@testable import AgentBooth

private actor PhaseRecorder {
    private(set) var phases: [RadioPhase] = []

    func append(_ phase: RadioPhase) {
        phases.append(phase)
    }
}

private actor StatusRecorder {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}

private final class LockedPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [RadioPhase] = []

    func append(_ phase: RadioPhase) {
        lock.lock()
        phases.append(phase)
        lock.unlock()
    }

    func snapshot() -> [RadioPhase] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}

private final class LockedPreGeneratePromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reviewItemBatches: [[ReviewScriptItem]] = []
    private var reusePromptCount = 0

    func appendReviewItems(_ items: [ReviewScriptItem]) {
        lock.lock()
        reviewItemBatches.append(items)
        lock.unlock()
    }

    func incrementReusePromptCount() {
        lock.lock()
        reusePromptCount += 1
        lock.unlock()
    }

    func latestReviewItems() -> [ReviewScriptItem]? {
        lock.lock()
        defer { lock.unlock() }
        return reviewItemBatches.last
    }

    func reviewCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reviewItemBatches.count
    }

    func reuseCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reusePromptCount
    }
}

private enum TestError: Error {
    case expectedFailure
}

final class RadioOrchestratorTests: XCTestCase {
    func testOrchestratorPublishesOpeningAndIntroPhases() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let phaseRecorder = LockedPhaseRecorder()
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            stateDidChange: { state in
                phaseRecorder.append(state.phase)
            }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let phases = phaseRecorder.snapshot()
            return phases.contains(.intro)
        }

        let phases = phaseRecorder.snapshot()
        XCTAssertTrue(phases.contains(.opening))
        XCTAssertTrue(phases.contains(.intro))
    }

    func testTransitionContinuityUsesSummaryBulletsInsteadOfDialogueText() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let scriptService = FakeScriptGenerationService()
        scriptService.openingScript = RadioScript(
            segmentType: "opening",
            dialogues: [
                DialogueLine(speaker: "male", text: "会話本文の一行目です"),
                DialogueLine(speaker: "female", text: "会話本文の二行目です"),
            ],
            summaryBullets: ["ライブ録音のざらついた質感に触れた"],
            track: nil
        )

        try await runShow(tracks: trackList, scriptService: scriptService)

        let transitionNotes = await scriptService.recordedTransitionContinuityNotes()
        let continuityNote = try XCTUnwrap(transitionNotes.first ?? nil)
        XCTAssertTrue(continuityNote.contains("Song A: ライブ録音のざらついた質感に触れた"))
        XCTAssertFalse(continuityNote.contains("male: 会話本文の一行目です"))
    }

    func testTransitionContinuityIncludesSessionTopicsAcrossDifferentArtists() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let scriptService = FakeScriptGenerationService()
        scriptService.openingScript = RadioScript(
            segmentType: "opening",
            dialogues: FakeScriptGenerationService.sampleDialogues(),
            summaryBullets: ["夜景の見えるスタジオの雰囲気に触れた"],
            track: nil
        )

        try await runShow(tracks: trackList, scriptService: scriptService)

        let transitionNotes = await scriptService.recordedTransitionContinuityNotes()
        let continuityNote = try XCTUnwrap(transitionNotes.first ?? nil)
        XCTAssertTrue(continuityNote.contains("番組内で既に触れた話題（重複回避）:"))
        XCTAssertTrue(continuityNote.contains("Song A: 夜景の見えるスタジオの雰囲気に触れた"))
        XCTAssertFalse(continuityNote.contains("同一アーティストとして直前に触れた内容:"))
        XCTAssertFalse(continuityNote.contains("同一アルバムとして直前に触れた内容:"))
    }

    func testTransitionContinuityFallsBackToDialogueExcerptWhenSummaryBulletsAreMissing() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let scriptService = FakeScriptGenerationService()
        scriptService.openingScript = RadioScript(
            segmentType: "opening",
            dialogues: [
                DialogueLine(speaker: "male", text: "最初の会話です"),
                DialogueLine(speaker: "female", text: "次の話題につなげます"),
            ],
            summaryBullets: [],
            track: nil
        )

        try await runShow(tracks: trackList, scriptService: scriptService)

        let transitionNotes = await scriptService.recordedTransitionContinuityNotes()
        let continuityNote = try XCTUnwrap(transitionNotes.first ?? nil)
        XCTAssertTrue(continuityNote.contains("Song A: male: 最初の会話です / female: 次の話題につなげます"))
    }

    func testArtistContinuityHistoryKeepsOnlyLatestTwoSummaryEntries() async throws {
        let trackList = [
            TrackInfo(name: "Song 1", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song 2", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song 3", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song 4", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let scriptService = FakeScriptGenerationService()

        try await runShow(tracks: trackList, scriptService: scriptService)

        let transitionNotes = await scriptService.recordedTransitionContinuityNotes().compactMap { $0 }
        let continuityNote = try XCTUnwrap(transitionNotes.last)
        var artistSection = continuityNote
        for sectionMarker in ["同一アルバムとして直前に触れた内容:", "番組内で既に触れた話題（重複回避）:"] {
            if let markerRange = artistSection.range(of: sectionMarker) {
                artistSection = String(artistSection[..<markerRange.lowerBound])
            }
        }
        let bulletLines = artistSection
            .split(separator: "\n")
            .filter { $0.hasPrefix("- ") }

        XCTAssertEqual(bulletLines.count, 2)
        XCTAssertTrue(continuityNote.contains("別の観点に切り替えること。"))
    }

    func testEnabledOverlapStartsTrackAtTalkVolumeThenFadesToNormalVolume() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.musicLeadSeconds = 0.05
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(settings: settings, musicService: musicService)

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.volumeHistory.contains(80)
        }

        let history = musicService.volumeHistory
        XCTAssertEqual(history.first, 20)
        XCTAssertTrue(history.contains(80))
    }

    func testDisabledOverlapStartsTrackAtNormalVolume() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(settings: settings, musicService: musicService)

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.playedTracks.count >= 1
        }

        XCTAssertEqual(musicService.volumeHistory.first, 80)
    }

    func testSpotifyOverlapStartsTrackBeforeNarrationEndsToCompensateStartupDelay() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let ttsService = SizedTTSService(audioDurationSeconds: 1.0)
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.musicLeadSeconds = 0.05
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            musicPlaybackProfile: MusicPlaybackProfile(startupLatencyCompensationSeconds: 0.35),
            ttsService: ttsService
        )

        let startedAt = Date()
        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.playedTracks.count >= 1
        }

        let firstTrackStart = try XCTUnwrap(musicService.playedTrackDates.first)
        XCTAssertLessThan(
            firstTrackStart.timeIntervalSince(startedAt),
            0.9,
            "Spotify は再生開始レイテンシ分だけ少し早めに開始すること"
        )
    }

    func testNextTrackStartsOnlyOnceAndClosingIsGenerated() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let steps = await scriptService.recordedGenerationSteps()
            return steps.contains("closing")
        }

        let generationSteps = await scriptService.recordedGenerationSteps()
        XCTAssertTrue(generationSteps.contains("transition:Song A->Song B"))
        XCTAssertTrue(generationSteps.contains("closing"))
        XCTAssertEqual(musicService.playedTracks.map(\.name), ["Song A", "Song B"])
    }

    func testDelayedTTSWaitsInsteadOfSkippingAndExtendsPastEffectiveEnd() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 3, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 3, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        scriptService.transitionScript = RadioScript(
            segmentType: "transition",
            dialogues: [DialogueLine(speaker: "male", text: "slow transition")],
            summaryBullets: ["遅いトランジション"],
            track: trackList[1]
        )
        let ttsService = ConditionalDelayTTSService(delaysByToken: ["slow transition": 1_500_000_000])
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.05
        settings.volumeSettings.maxPlaybackDurationSeconds = 1

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.playedTracks.count >= 2
        }

        XCTAssertEqual(musicService.playedTracks.map(\.name), ["Song A", "Song B"])
        let firstStart = try XCTUnwrap(musicService.playedTrackDates.first)
        let secondStart = try XCTUnwrap(musicService.playedTrackDates.dropFirst().first)
        XCTAssertGreaterThan(secondStart.timeIntervalSince(firstStart), 1.3, "実効終端を越えて TTS 完了まで待つこと")
    }

    func testOverlapEnabledDucksCurrentTrackBeforeFadeOut() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.fadeEarlySeconds = 1
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(settings: settings, musicService: musicService)

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.playedTracks.count >= 2
        }

        let history = musicService.volumeHistory
        let normalIndex = try XCTUnwrap(history.firstIndex(of: 80))
        let duckIndex = try XCTUnwrap(history[(normalIndex + 1)...].firstIndex(of: 20))
        let fadeOutIndex = try XCTUnwrap(history.firstIndex(of: 0))
        XCTAssertLessThan(duckIndex, fadeOutIndex)
    }

    func testOverlapTransitionStartsBedOnlyAfterTrackStops() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let bedAudioPlaybackService = FakeBedAudioPlaybackService()
        let ttsService = SizedTTSService(audioDurationSeconds: 0.4)
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.fadeEarlySeconds = 1
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.05
        settings.bgmSettings.isBedEnabled = true

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            ttsService: ttsService,
            bedAudioPlaybackService: bedAudioPlaybackService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let startBedDates = await bedAudioPlaybackService.startBedDates
            guard let firstStopDate = musicService.stoppedTrackDates.first else {
                return false
            }
            return startBedDates.contains { $0 > firstStopDate }
        }

        let firstStartDate = try XCTUnwrap(musicService.playedTrackDates.first)
        let firstStopDate = try XCTUnwrap(musicService.stoppedTrackDates.first)
        let startBedDates = await bedAudioPlaybackService.startBedDates
        let startsWhileTrackIsPlaying = startBedDates.filter { $0 > firstStartDate && $0 < firstStopDate }
        XCTAssertTrue(startsWhileTrackIsPlaying.isEmpty)
        XCTAssertTrue(startBedDates.contains { $0 > firstStopDate })
    }

    func testOverlapFadeOutContinuesPastEffectiveTrackEnd() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        scriptService.transitionScript = RadioScript(
            segmentType: "transition",
            dialogues: [DialogueLine(speaker: "male", text: "late transition")],
            summaryBullets: ["遅れて完成するトランジション"],
            track: trackList[1]
        )
        let ttsService = ConditionalDelayTTSService(delaysByToken: ["late transition": 950_000_000])
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.fadeEarlySeconds = 1
        settings.volumeSettings.fadeDuration = 0.5
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.stoppedTrackDates.count >= 1
        }

        let firstStart = try XCTUnwrap(musicService.playedTrackDates.first)
        let firstStop = try XCTUnwrap(musicService.stoppedTrackDates.first)
        XCTAssertGreaterThan(
            firstStop.timeIntervalSince(firstStart),
            1.35,
            "フェード開始後は曲終了が近くても fadeDuration 分のフェードを優先すること"
        )
    }

    func testRecordingServiceIsStartedAndStoppedDuringShow() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let recordingService = FakeRecordingService()
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            recordingService: recordingService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let stopCount = await recordingService.stopCallCount
            return stopCount >= 1
        }

        let startCount = await recordingService.startCallCount
        let stopCount = await recordingService.stopCallCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testStatusShowsCredentialSetAndModelAfterTTSSynthesis() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let statusRecorder = StatusRecorder()
        let ttsService = FakeTTSService()
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        settings.ttsCredentialSets = [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
        ]

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            ttsService: ttsService,
            stateDidChange: { state in
                let statusMessage = state.statusMessage
                if !statusMessage.isEmpty {
                    Task { await statusRecorder.append(statusMessage) }
                }
            }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let messages = await statusRecorder.messages
            return messages.contains("TTS音声作成終了（セット: main / モデル: model-1）")
        }

        let messages = await statusRecorder.messages
        XCTAssertTrue(messages.contains("TTS音声作成終了（セット: main / モデル: model-1）"))
    }

    func testPreGeneratedScriptReuseSkipsScriptGenerationAndClearsAfterSuccess() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let scriptStore = FakePreGeneratedScriptStore(session: makePersistedSession(tracks: trackList))
        let promptRecorder = LockedPreGeneratePromptRecorder()

        let orchestrator = makeOrchestrator(
            settings: makeFastPreGenerateSettings(),
            musicService: musicService,
            scriptService: scriptService,
            scriptStore: scriptStore,
            reviewDidBecomeAvailable: { items in
                promptRecorder.appendReviewItems(items)
            },
            reusePromptDidBecomeAvailable: {
                promptRecorder.incrementReusePromptCount()
            }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            promptRecorder.reuseCount() == 1
        }
        await orchestrator.confirmReuse()
        try await waitUntil {
            promptRecorder.reviewCount() == 1
        }
        let reviewItems = try XCTUnwrap(promptRecorder.latestReviewItems())
        await orchestrator.approveScripts(reviewItems)
        try await waitUntil {
            await scriptStore.clearCallCount >= 1
        }

        let steps = await scriptService.recordedGenerationSteps()
        let saveCallCount = await scriptStore.saveCallCount
        let savedSession = await scriptStore.session
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(saveCallCount, 1)
        XCTAssertNil(savedSession)
    }

    func testPreGeneratedScriptReuseDeclineClearsAndRegeneratesScripts() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let scriptStore = FakePreGeneratedScriptStore(session: makePersistedSession(tracks: trackList))
        let promptRecorder = LockedPreGeneratePromptRecorder()

        let orchestrator = makeOrchestrator(
            settings: makeFastPreGenerateSettings(),
            musicService: musicService,
            scriptService: scriptService,
            scriptStore: scriptStore,
            reviewDidBecomeAvailable: { items in
                promptRecorder.appendReviewItems(items)
            },
            reusePromptDidBecomeAvailable: {
                promptRecorder.incrementReusePromptCount()
            }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            promptRecorder.reuseCount() == 1
        }
        await orchestrator.declineReuse()
        try await waitUntil {
            promptRecorder.reviewCount() == 1
        }
        let reviewItems = try XCTUnwrap(promptRecorder.latestReviewItems())
        await orchestrator.approveScripts(reviewItems)
        try await waitUntil {
            await scriptStore.saveCallCount == 1
        }

        let steps = await scriptService.recordedGenerationSteps()
        let clearCallCount = await scriptStore.clearCallCount
        let saveCallCount = await scriptStore.saveCallCount
        XCTAssertTrue(steps.contains("opening"))
        XCTAssertTrue(steps.contains("closing"))
        XCTAssertGreaterThanOrEqual(clearCallCount, 1)
        XCTAssertEqual(saveCallCount, 1)
    }

    func testPreGeneratedScriptStoreKeepsSavedSessionAfterTTSError() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptStore = FakePreGeneratedScriptStore()
        let promptRecorder = LockedPreGeneratePromptRecorder()
        let ttsService = FailingTTSService(error: TestError.expectedFailure)

        let orchestrator = makeOrchestrator(
            settings: makeFastPreGenerateSettings(),
            musicService: musicService,
            ttsService: ttsService,
            scriptStore: scriptStore,
            reviewDidBecomeAvailable: { items in
                promptRecorder.appendReviewItems(items)
            }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            promptRecorder.reviewCount() == 1
        }
        let reviewItems = try XCTUnwrap(promptRecorder.latestReviewItems())
        await orchestrator.approveScripts(reviewItems)
        try await waitUntil {
            await scriptStore.saveCallCount == 1
        }

        let clearCallCount = await scriptStore.clearCallCount
        let savedSession = await scriptStore.session
        XCTAssertEqual(clearCallCount, 0)
        XCTAssertNotNil(savedSession)
    }

    func testCueSheetRecordsTrackNarrationAndFadeEvents() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let cueSheetLogger = try makeCueSheetLogger()
        let ttsService = SizedTTSService(audioDurationSeconds: 0.2)
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.normalVolume = 80
        settings.volumeSettings.talkVolume = 20
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0.05
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            ttsService: ttsService,
            cueSheetLogger: cueSheetLogger
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            guard musicService.stoppedTrackDates.count >= 1,
                  let cueSheetText = try? await self.readCueSheetText(from: cueSheetLogger) else {
                return false
            }
            return cueSheetText.contains("フェードアウト開始(")
                && cueSheetText.contains("曲再生終了(Song A / Artist A / Album A)")
        }

        let cueSheetText = try await readCueSheetText(from: cueSheetLogger)
        XCTAssertTrue(cueSheetText.contains("次曲(1/1 Song A / Artist A / Album A)"))
        XCTAssertTrue(cueSheetText.contains("曲選択(1/1 Song A / Artist A / Album A)"))
        XCTAssertTrue(cueSheetText.contains("音量設定(20%)"))
        XCTAssertTrue(cueSheetText.contains("曲再生開始(Song A / Artist A / Album A)"))
        XCTAssertTrue(cueSheetText.contains("TTS再生開始(オープニング)"))
        XCTAssertTrue(cueSheetText.contains("TTS再生終了(オープニング)"))
        XCTAssertTrue(cueSheetText.contains("フェードイン開始(20% → 80%"))
        XCTAssertTrue(cueSheetText.contains("フェードアウト開始("))
        XCTAssertTrue(cueSheetText.contains("曲再生終了(Song A / Artist A / Album A)"))
    }

    func testShowRunsNormallyWithoutRecordingService() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let phaseRecorder = PhaseRecorder()
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            stateDidChange: { state in
                Task { await phaseRecorder.append(state.phase) }
            }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let phases = await phaseRecorder.phases
            return phases.contains(.idle) && phases.count > 1
        }

        let phases = await phaseRecorder.phases
        XCTAssertTrue(phases.contains(.opening))
    }

    func testOpeningJingleAndBedAreStartedWhenEnabled() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let bedAudioPlaybackService = FakeBedAudioPlaybackService()
        await bedAudioPlaybackService.setJingleDurationToReturn(0.05)
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.bgmSettings.isBedEnabled = true
        settings.bgmSettings.isOpeningJingleEnabled = true

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            bedAudioPlaybackService: bedAudioPlaybackService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let playJingleCallCount = await bedAudioPlaybackService.playJingleCallCount
            let startBedCallCount = await bedAudioPlaybackService.startBedCallCount
            let fadeOutAndStopBedCallCount = await bedAudioPlaybackService.fadeOutAndStopBedCallCount
            return playJingleCallCount >= 1 && startBedCallCount >= 1 && fadeOutAndStopBedCallCount >= 1
        }

        let lastJinglePlacement = await bedAudioPlaybackService.lastJinglePlacement
        let fadeOutAndStopBedCallCount = await bedAudioPlaybackService.fadeOutAndStopBedCallCount
        XCTAssertEqual(lastJinglePlacement, .opening)
        XCTAssertGreaterThanOrEqual(fadeOutAndStopBedCallCount, 1)
    }

    func testTransitionDoesNotPlayJingle() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let bedAudioPlaybackService = FakeBedAudioPlaybackService()
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.bgmSettings.isOpeningJingleEnabled = true
        settings.bgmSettings.isClosingJingleEnabled = false

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            bedAudioPlaybackService: bedAudioPlaybackService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            musicService.playedTracks.count >= 2
        }

        let playJingleCallCount = await bedAudioPlaybackService.playJingleCallCount
        let lastJinglePlacement = await bedAudioPlaybackService.lastJinglePlacement
        XCTAssertEqual(playJingleCallCount, 1)
        XCTAssertEqual(lastJinglePlacement, .opening)
    }

    func testTimeBasedDirectionPresetIsPassedToScriptAndTTS() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let ttsService = FakeTTSService()
        var settings = AppSettings()
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.fadeDuration = 0.01
        settings.directionSettings.sceneDirection = "共通ディレクション"
        TimeBand.allCases.forEach { timeBand in
            settings.directionSettings.timeBasedPresets[timeBand] = "時間帯に合わせて話す"
        }

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            currentDateProvider: { Date(timeIntervalSince1970: 1_811_076_400) }
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let scriptSettings = await scriptService.recordedSettings()
            let ttsSettings = await ttsService.recordedSettings
            return !scriptSettings.isEmpty && !ttsSettings.isEmpty
        }
        await orchestrator.stopShow()

        let recordedScriptSettings = await scriptService.recordedSettings()
        let recordedTTSSettings = await ttsService.recordedSettings
        let scriptDirection = try XCTUnwrap(recordedScriptSettings.first)
            .directionSettings.sceneDirection
        let ttsDirection = try XCTUnwrap(recordedTTSSettings.first)
            .directionSettings.sceneDirection
        XCTAssertTrue(scriptDirection.contains("共通ディレクション"))
        XCTAssertTrue(scriptDirection.contains("時間帯別ディレクション（"))
        XCTAssertTrue(scriptDirection.contains("時間帯に合わせて話す"))
        XCTAssertEqual(ttsDirection, scriptDirection)
    }

    private func makeFastPreGenerateSettings() -> AppSettings {
        var settings = AppSettings()
        settings.defaultScriptGenerationMode = .preGenerate
        settings.defaultOverlapMode = .disabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.01
        return settings
    }

    private func makePersistedSession(tracks: [TrackInfo]) -> PersistedScriptSession {
        let settings = makeFastPreGenerateSettings().strippingSecrets()
        let openingScript = RadioScript(
            segmentType: "opening",
            dialogues: FakeScriptGenerationService.sampleDialogues(),
            summaryBullets: ["保存済みオープニング"],
            track: tracks.first
        )
        let closingScript = RadioScript(
            segmentType: "closing",
            dialogues: FakeScriptGenerationService.sampleDialogues(),
            summaryBullets: ["保存済みクロージング"],
            track: tracks.last
        )
        return PersistedScriptSession(
            playlistName: "Favorites",
            trackFingerprint: tracks.map(\.id).joined(separator: "\n"),
            tracks: tracks,
            segments: [
                PersistedSegment(key: "opening", script: openingScript, narrationSettings: settings),
                PersistedSegment(key: "closing", script: closingScript, narrationSettings: settings),
            ],
            savedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeOrchestrator(
        settings: AppSettings = AppSettings(),
        musicService: FakeMusicService,
        musicPlaybackProfile: MusicPlaybackProfile = MusicPlaybackProfile(),
        scriptService: FakeScriptGenerationService = FakeScriptGenerationService(),
        ttsService: any TTSService = FakeTTSService(),
        audioPlaybackService: any AudioPlaybackServiceProtocol = FakeAudioPlaybackService(),
        bedAudioPlaybackService: any BedAudioPlaybackServiceProtocol = FakeBedAudioPlaybackService(),
        recordingService: (any ShowRecordingServiceProtocol)? = nil,
        cueSheetLogger: ShowCueSheetLogger? = nil,
        scriptStore: (any PreGeneratedScriptStoreProtocol)? = nil,
        currentDateProvider: @escaping @Sendable () -> Date = { Date() },
        reviewDidBecomeAvailable: (@Sendable ([ReviewScriptItem]) -> Void)? = nil,
        reusePromptDidBecomeAvailable: (@Sendable () -> Void)? = nil,
        stateDidChange: @escaping @Sendable (RadioState) -> Void = { _ in }
    ) -> RadioOrchestrator {
        RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            musicPlaybackProfile: musicPlaybackProfile,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService,
            bedAudioPlaybackService: bedAudioPlaybackService,
            recordingService: recordingService,
            cueSheetLogger: cueSheetLogger,
            scriptStore: scriptStore,
            currentDateProvider: currentDateProvider,
            reviewDidBecomeAvailable: reviewDidBecomeAvailable,
            reusePromptDidBecomeAvailable: reusePromptDidBecomeAvailable,
            stateDidChange: stateDidChange
        )
    }

    private func runShow(
        tracks: [TrackInfo],
        scriptService: FakeScriptGenerationService,
        ttsService: any TTSService = FakeTTSService(),
        overlapMode: OverlapMode = .enabled
    ) async throws {
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": tracks])
        var settings = AppSettings()
        settings.defaultOverlapMode = overlapMode
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        settings.volumeSettings.fadeDuration = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService
        )

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let transitionNotes = await scriptService.recordedTransitionContinuityNotes()
            return transitionNotes.count >= max(0, tracks.count - 1)
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        intervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func makeCueSheetLogger() throws -> ShowCueSheetLogger {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return ShowCueSheetLogger(sessionDirectoryURL: directoryURL)
    }

    private func readCueSheetText(from logger: ShowCueSheetLogger) async throws -> String {
        let fileURL = try await logger.cueSheetFileURL()
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
