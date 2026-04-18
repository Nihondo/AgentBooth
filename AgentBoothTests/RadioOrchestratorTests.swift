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

final class RadioOrchestratorTests: XCTestCase {
    func testOrchestratorPublishesExpectedPhases() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let phaseRecorder = PhaseRecorder()
        var settings = AppSettings()
        settings.defaultOverlapMode = .enabled
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0.05

        let orchestrator = makeOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService
        ) { state in
            Task { await phaseRecorder.append(state.phase) }
        }

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let phases = await phaseRecorder.phases
            return phases.contains(.closing)
        }

        let phases = await phaseRecorder.phases
        XCTAssertTrue(phases.contains(.opening))
        XCTAssertTrue(phases.contains(.intro))
        XCTAssertTrue(phases.contains(.playing))
        XCTAssertTrue(phases.contains(.outro))
        XCTAssertTrue(phases.contains(.closing))
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

    func testContinuityHistoryKeepsOnlyLatestTwoSummaryEntries() async throws {
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
        let bulletLines = continuityNote
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
        let musicService = FakeMusicService(
            serviceKind: .spotify,
            playlists: ["Favorites"],
            tracksByPlaylist: ["Favorites": trackList]
        )
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
            ttsService: ttsService
        ) { state in
            let statusMessage = state.statusMessage
            if !statusMessage.isEmpty {
                Task { await statusRecorder.append(statusMessage) }
            }
        }

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let messages = await statusRecorder.messages
            return messages.contains("TTS音声作成終了（セット: main / モデル: model-1）")
        }

        let messages = await statusRecorder.messages
        XCTAssertTrue(messages.contains("TTS音声作成終了（セット: main / モデル: model-1）"))
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
            musicService: musicService
        ) { state in
            Task { await phaseRecorder.append(state.phase) }
        }

        await orchestrator.startShow(playlistName: "Favorites")
        try await waitUntil {
            let phases = await phaseRecorder.phases
            return phases.contains(.idle) && phases.count > 1
        }

        let phases = await phaseRecorder.phases
        XCTAssertTrue(phases.contains(.opening))
    }

    private func makeOrchestrator(
        settings: AppSettings = AppSettings(),
        musicService: FakeMusicService,
        scriptService: FakeScriptGenerationService = FakeScriptGenerationService(),
        ttsService: any TTSService = FakeTTSService(),
        audioPlaybackService: any AudioPlaybackServiceProtocol = FakeAudioPlaybackService(),
        recordingService: (any ShowRecordingServiceProtocol)? = nil,
        stateDidChange: @escaping @Sendable (RadioState) -> Void = { _ in }
    ) -> RadioOrchestrator {
        RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService,
            recordingService: recordingService,
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
}
