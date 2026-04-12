import Foundation
@testable import AgentBooth

final class FakeMusicService: @unchecked Sendable, MusicService {
    let serviceKind: MusicServiceKind
    var playlists: [String]
    var tracksByPlaylist: [String: [TrackInfo]]
    var playedTracks: [TrackInfo] = []
    var currentVolume: Int = 100
    var isPlaying = false

    init(
        serviceKind: MusicServiceKind = .appleMusic,
        playlists: [String] = [],
        tracksByPlaylist: [String: [TrackInfo]] = [:]
    ) {
        self.serviceKind = serviceKind
        self.playlists = playlists
        self.tracksByPlaylist = tracksByPlaylist
    }

    func fetchPlaylists() async throws -> [String] { playlists }

    func fetchTracks(in playlistName: String) async throws -> [TrackInfo] {
        tracksByPlaylist[playlistName] ?? []
    }

    func play(track: TrackInfo) async throws {
        playedTracks.append(track)
        isPlaying = true
    }

    func stopPlayback() async {
        isPlaying = false
    }

    func pausePlayback() async {
        isPlaying = false
    }

    func resumePlayback() async {
        isPlaying = true
    }

    func setVolume(level: Int) async {
        currentVolume = level
    }

    func fetchVolume() async -> Int { currentVolume }

    func fetchCurrentTrack() async throws -> TrackInfo? { playedTracks.last }

    func fetchIsPlaying() async -> Bool { isPlaying }
}

final class FakeScriptGenerationService: @unchecked Sendable, ScriptGenerationService {
    private let continuityRecorder = ContinuityNoteRecorder()

    var openingScript = RadioScript(
        segmentType: "opening",
        dialogues: FakeScriptGenerationService.sampleDialogues(),
        summaryBullets: ["オープニングで触れた話題"],
        track: nil
    )
    var introScript = RadioScript(
        segmentType: "intro",
        dialogues: FakeScriptGenerationService.sampleDialogues(),
        summaryBullets: ["イントロで触れた話題"],
        track: nil
    )
    var transitionScript = RadioScript(
        segmentType: "transition",
        dialogues: FakeScriptGenerationService.sampleDialogues(),
        summaryBullets: ["トランジションで触れた話題"],
        track: nil
    )
    var closingScript = RadioScript(
        segmentType: "closing",
        dialogues: FakeScriptGenerationService.sampleDialogues(),
        summaryBullets: ["クロージングで触れた話題"],
        track: nil
    )

    func generateOpening(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        RadioScript(
            segmentType: openingScript.segmentType,
            dialogues: openingScript.dialogues,
            summaryBullets: openingScript.summaryBullets,
            track: tracks.first
        )
    }

    func generateIntro(track: TrackInfo, settings: AppSettings, continuityNote: String?) async throws -> RadioScript {
        await continuityRecorder.recordIntro(continuityNote)
        return RadioScript(
            segmentType: introScript.segmentType,
            dialogues: introScript.dialogues,
            summaryBullets: introScript.summaryBullets,
            track: track
        )
    }

    func generateTransition(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        settings: AppSettings,
        continuityNote: String?
    ) async throws -> RadioScript {
        await continuityRecorder.recordTransition(continuityNote)
        return RadioScript(
            segmentType: transitionScript.segmentType,
            dialogues: transitionScript.dialogues,
            summaryBullets: transitionScript.summaryBullets,
            track: nextTrack
        )
    }

    func generateClosing(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        RadioScript(
            segmentType: closingScript.segmentType,
            dialogues: closingScript.dialogues,
            summaryBullets: closingScript.summaryBullets,
            track: tracks.last
        )
    }

    func recordedIntroContinuityNotes() async -> [String?] {
        await continuityRecorder.introNotes
    }

    func recordedTransitionContinuityNotes() async -> [String?] {
        await continuityRecorder.transitionNotes
    }

    static func sampleDialogues() -> [DialogueLine] {
        [
            DialogueLine(speaker: "male", text: "こんにちは"),
            DialogueLine(speaker: "female", text: "こんばんは"),
        ]
    }
}

private actor ContinuityNoteRecorder {
    private(set) var introNotes: [String?] = []
    private(set) var transitionNotes: [String?] = []

    func recordIntro(_ note: String?) {
        introNotes.append(note)
    }

    func recordTransition(_ note: String?) {
        transitionNotes.append(note)
    }
}

actor FakeTTSService: TTSService {
    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        var wavData = Data(repeating: 0, count: 44)
        wavData.append(Data(repeating: 1, count: 4_800))
        return TTSResult(wavData: wavData, modelUsed: settings.geminiTTSModel)
    }
}

actor FailingTTSService: TTSService {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        throw error
    }
}

actor FakeAudioPlaybackService: AudioPlaybackServiceProtocol {
    private(set) var playCount = 0
    private(set) var isPlaying = false

    func play(wavData: Data) async throws {
        playCount += 1
        isPlaying = true
        try await Task.sleep(nanoseconds: 10_000_000)
        isPlaying = false
    }

    func stopPlayback() async {
        isPlaying = false
    }

    func pausePlayback() async {}

    func resumePlayback() async {}

    func fetchIsPlaying() async -> Bool { isPlaying }
}

struct FakeServiceFactory: AppServiceFactory {
    let musicService: FakeMusicService
    let scriptService: FakeScriptGenerationService
    let ttsService: any TTSService
    let audioPlaybackService: any AudioPlaybackServiceProtocol
    let supportedServices: [MusicServiceKind]

    init(
        musicService: FakeMusicService,
        scriptService: FakeScriptGenerationService = FakeScriptGenerationService(),
        ttsService: any TTSService = FakeTTSService(),
        audioPlaybackService: any AudioPlaybackServiceProtocol = FakeAudioPlaybackService(),
        supportedServices: [MusicServiceKind] = [.appleMusic]
    ) {
        self.musicService = musicService
        self.scriptService = scriptService
        self.ttsService = ttsService
        self.audioPlaybackService = audioPlaybackService
        self.supportedServices = supportedServices
    }

    func availableServices() -> [MusicServiceKind] { supportedServices }

    func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService { musicService }

    func makeScriptService(settings: AppSettings) -> any ScriptGenerationService { scriptService }

    func makeTTSService(settings: AppSettings) -> any TTSService { ttsService }

    func makeAudioPlaybackService() -> any AudioPlaybackServiceProtocol { audioPlaybackService }
}
