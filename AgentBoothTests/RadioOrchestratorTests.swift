import XCTest
@testable import AgentBooth

private actor PhaseRecorder {
    private(set) var phases: [RadioPhase] = []

    func append(_ phase: RadioPhase) {
        phases.append(phase)
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
        let ttsService = FakeTTSService()
        let audioPlaybackService = FakeAudioPlaybackService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        let phaseRecorder = PhaseRecorder()

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { state in
            Task {
                await phaseRecorder.append(state.phase)
            }
        }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .fullRadio)
        var recordedPhases: [RadioPhase] = []
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 100_000_000)
            recordedPhases = await phaseRecorder.phases
            if recordedPhases.contains(.closing) {
                break
            }
        }

        XCTAssertTrue(recordedPhases.contains(.opening))
        XCTAssertTrue(recordedPhases.contains(.intro))
        XCTAssertTrue(recordedPhases.contains(.playing))
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

        try await runShow(
            tracks: trackList,
            scriptService: scriptService
        )

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

        try await runShow(
            tracks: trackList,
            scriptService: scriptService
        )

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

        try await runShow(
            tracks: trackList,
            scriptService: scriptService
        )

        let transitionNotes = await scriptService.recordedTransitionContinuityNotes().compactMap { $0 }
        let continuityNote = try XCTUnwrap(transitionNotes.last)
        let bulletLines = continuityNote
            .split(separator: "\n")
            .filter { $0.hasPrefix("- ") }

        XCTAssertEqual(bulletLines.count, 2)
        XCTAssertTrue(continuityNote.contains("別の観点に切り替えること。"))
    }

    func testLastTrackSkipsDuplicateIntroAndPreparesClosing() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let ttsService = FakeTTSService()
        let audioPlaybackService = FakeAudioPlaybackService()
        let phaseRecorder = PhaseRecorder()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { state in
            Task { await phaseRecorder.append(state.phase) }
        }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .fullRadio)

        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let phases = await phaseRecorder.phases
            if musicService.playedTracks.count >= 2 || phases.contains(.closing) {
                break
            }
        }

        let generationSteps = await scriptService.recordedGenerationSteps()
        let playedTrackNames = musicService.playedTracks.map(\.name)
        XCTAssertTrue(generationSteps.contains("transition:Song A->Song B"))
        XCTAssertEqual(playedTrackNames, ["Song A", "Song B"], "次の曲が二重に開始されないこと")
    }

    func testLastTrackFadesOutBeforeClosing() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let ttsService = FakeTTSService()
        let audioPlaybackService = FakeAudioPlaybackService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 1
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { _ in }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .sequential)

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !musicService.isPlaying {
                break
            }
        }

        XCTAssertTrue(musicService.volumeHistory.contains(0), "最後の曲は停止前に 0 までフェードアウトすること")
    }

    func testShortTrackCompressesFadeOutToRemainingPlaybackTime() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let ttsService = FakeTTSService()
        let audioPlaybackService = FakeAudioPlaybackService()
        let phaseRecorder = PhaseRecorder()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 5
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { state in
            Task { await phaseRecorder.append(state.phase) }
        }

        let startedAt = ContinuousClock.now
        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .sequential)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let phases = await phaseRecorder.phases
            if phases.contains(.closing), phases.last == .idle {
                break
            }
        }

        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000

        XCTAssertTrue(musicService.volumeHistory.contains(0), "短い曲でも停止前に 0 までフェードアウトすること")
        XCTAssertLessThan(elapsedSeconds, 3.0, "短い曲のフェードは残り再生時間に圧縮されること")
    }

    func testTransitionFallsBackToStandaloneIntroWhenTransitionTTSMissesDeadline() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        scriptService.transitionScript = RadioScript(
            segmentType: "transition",
            dialogues: [DialogueLine(speaker: "male", text: "delay-transition")],
            summaryBullets: ["トランジションで触れた話題"],
            track: nil
        )
        scriptService.introScript = RadioScript(
            segmentType: "intro",
            dialogues: [DialogueLine(speaker: "female", text: "ready-intro")],
            summaryBullets: ["イントロで触れた話題"],
            track: nil
        )
        let ttsService = ConditionalDelayTTSService(delaysByToken: ["delay-transition": 2_000_000_000])
        let audioPlaybackService = FakeAudioPlaybackService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 1
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { _ in }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .fullRadio)

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (await audioPlaybackService.playCount) >= 3 {
                break
            }
        }

        let generationSteps = await scriptService.recordedGenerationSteps()
        let playCount = await audioPlaybackService.playCount
        XCTAssertTrue(generationSteps.contains("transition:Song A->Song B"))
        XCTAssertTrue(generationSteps.contains("intro:Song B"))
        XCTAssertEqual(playCount, 3, "オープニング・次曲イントロ・クロージングのみが再生されること")
    }

    func testIntroSkipsNarrationWhenIntroTTSMissesDeadline() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 1, playlistName: "Favorites"),
            TrackInfo(name: "Song B", artist: "Artist B", album: "Album B", durationSeconds: 1, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        scriptService.transitionScript = RadioScript(
            segmentType: "transition",
            dialogues: [DialogueLine(speaker: "male", text: "delay-transition")],
            summaryBullets: ["トランジションで触れた話題"],
            track: nil
        )
        scriptService.introScript = RadioScript(
            segmentType: "intro",
            dialogues: [DialogueLine(speaker: "female", text: "delay-intro")],
            summaryBullets: ["イントロで触れた話題"],
            track: nil
        )
        let ttsService = ConditionalDelayTTSService(
            delaysByToken: [
                "delay-transition": 2_000_000_000,
                "delay-intro": 2_000_000_000,
            ]
        )
        let audioPlaybackService = FakeAudioPlaybackService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 1
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { _ in }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .fullRadio)

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !musicService.isPlaying, (await audioPlaybackService.playCount) >= 2 {
                break
            }
        }

        let generationSteps = await scriptService.recordedGenerationSteps()
        let playCount = await audioPlaybackService.playCount
        let playedTrackNames = musicService.playedTracks.map(\.name)
        XCTAssertTrue(generationSteps.contains("transition:Song A->Song B"))
        XCTAssertTrue(generationSteps.contains("intro:Song B"))
        XCTAssertEqual(playCount, 2, "オープニングとクロージングのみが再生されること")
        XCTAssertEqual(playedTrackNames, ["Song A", "Song B"])
    }

    func testRecordingServiceIsStartedAndStoppedDuringShow() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let ttsService = FakeTTSService()
        let audioPlaybackService = FakeAudioPlaybackService()
        let recordingService = FakeRecordingService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService,
            recordingService: recordingService
        ) { _ in }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .sequential)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let stopCount = await recordingService.stopCallCount
            if stopCount >= 1 { break }
        }

        let startCount = await recordingService.startCallCount
        let stopCount = await recordingService.stopCallCount
        XCTAssertEqual(startCount, 1, "startRecording が1回呼ばれること")
        XCTAssertEqual(stopCount, 1, "stopRecording が1回呼ばれること")
    }

    func testShowRunsNormallyWithoutRecordingService() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let scriptService = FakeScriptGenerationService()
        let ttsService = FakeTTSService()
        let audioPlaybackService = FakeAudioPlaybackService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0
        let phaseRecorder = PhaseRecorder()

        // recordingService = nil（既定値）
        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { state in
            Task { await phaseRecorder.append(state.phase) }
        }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: .sequential)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let phases = await phaseRecorder.phases
            if phases.contains(.idle) && phases.count > 1 { break }
        }

        let phases = await phaseRecorder.phases
        XCTAssertTrue(phases.contains(.opening), "録音サービスなしでも番組が正常に動作すること")
    }

    private func runShow(
        tracks: [TrackInfo],
        scriptService: FakeScriptGenerationService,
        ttsService: any TTSService = FakeTTSService(),
        overlapMode: OverlapMode = .fullRadio
    ) async throws {
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": tracks])
        let audioPlaybackService = FakeAudioPlaybackService()
        var settings = AppSettings()
        settings.volumeSettings.fadeEarlySeconds = 0
        settings.volumeSettings.musicLeadSeconds = 0

        let orchestrator = RadioOrchestrator(
            settings: settings,
            musicService: musicService,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService
        ) { _ in }

        await orchestrator.startShow(playlistName: "Favorites", overlapMode: overlapMode)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let transitionNotes = await scriptService.recordedTransitionContinuityNotes()
            if transitionNotes.count >= max(0, tracks.count - 1) {
                break
            }
        }
    }
}
