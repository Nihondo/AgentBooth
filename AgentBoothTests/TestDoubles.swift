import Foundation
@testable import AgentBooth

final class FakeMusicService: @unchecked Sendable, MusicService {
    var playlists: [String]
    var tracksByPlaylist: [String: [TrackInfo]]
    var playedTracks: [TrackInfo] = []
    var playedTrackDates: [Date] = []
    var stoppedTrackDates: [Date] = []
    var currentVolume: Int = 100
    var volumeHistory: [Int] = []
    var volumeChangeDates: [Date] = []
    var isVolumeFetchAvailable = true
    var setVolumeDelayNanoseconds: UInt64 = 0
    var isPlaying = false
    var currentPosition: Double = 0

    init(
        playlists: [String] = [],
        tracksByPlaylist: [String: [TrackInfo]] = [:]
    ) {
        self.playlists = playlists
        self.tracksByPlaylist = tracksByPlaylist
    }

    func fetchPlaylists() async throws -> [String] { playlists }

    func fetchTracks(in playlistName: String) async throws -> [TrackInfo] {
        tracksByPlaylist[playlistName] ?? []
    }

    func play(track: TrackInfo) async throws {
        playedTracks.append(track)
        playedTrackDates.append(Date())
        isPlaying = true
    }

    func stopPlayback() async {
        isPlaying = false
        stoppedTrackDates.append(Date())
    }

    func pausePlayback() async {
        isPlaying = false
    }

    func resumePlayback() async {
        isPlaying = true
    }

    func setVolume(level: Int) async {
        if setVolumeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setVolumeDelayNanoseconds)
        }
        currentVolume = level
        volumeHistory.append(level)
        volumeChangeDates.append(Date())
    }

    func fetchVolume() async -> Int? {
        isVolumeFetchAvailable ? currentVolume : nil
    }

    func fetchCurrentTrack() async throws -> TrackInfo? { playedTracks.last }

    func fetchIsPlaying() async -> Bool { isPlaying }

    func fetchPlaybackPosition() async -> Double { currentPosition }

    func seekToPosition(_ seconds: Double) async { currentPosition = seconds }
}

final class FakeScriptGenerationService: @unchecked Sendable, ScriptGenerationService {
    private let continuityRecorder = ContinuityNoteRecorder()
    private let generationStepRecorder = GenerationStepRecorder()
    private let settingsRecorder = ScriptSettingsRecorder()

    var openingScript = RadioScript(
        segmentType: "opening",
        dialogues: FakeScriptGenerationService.sampleDialogues(),
        summaryBullets: ["オープニングで触れた話題"],
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
        await settingsRecorder.record(settings)
        await generationStepRecorder.record("opening")
        return RadioScript(
            segmentType: openingScript.segmentType,
            dialogues: openingScript.dialogues,
            summaryBullets: openingScript.summaryBullets,
            track: tracks.first
        )
    }

    func generateTransition(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        settings: AppSettings,
        continuityNote: String?
    ) async throws -> RadioScript {
        await settingsRecorder.record(settings)
        await continuityRecorder.recordTransition(continuityNote)
        await generationStepRecorder.record("transition:\(currentTrack.name)->\(nextTrack.name)")
        return RadioScript(
            segmentType: transitionScript.segmentType,
            dialogues: transitionScript.dialogues,
            summaryBullets: transitionScript.summaryBullets,
            track: nextTrack
        )
    }

    func generateClosing(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        await settingsRecorder.record(settings)
        await generationStepRecorder.record("closing")
        return RadioScript(
            segmentType: closingScript.segmentType,
            dialogues: closingScript.dialogues,
            summaryBullets: closingScript.summaryBullets,
            track: tracks.last
        )
    }

    func recordedTransitionContinuityNotes() async -> [String?] {
        await continuityRecorder.transitionNotes
    }

    func recordedGenerationSteps() async -> [String] {
        await generationStepRecorder.steps
    }

    func recordedSettings() async -> [AppSettings] {
        await settingsRecorder.settings
    }

    static func sampleDialogues() -> [DialogueLine] {
        [
            DialogueLine(speaker: "male", text: "こんにちは"),
            DialogueLine(speaker: "female", text: "こんばんは"),
        ]
    }
}

private actor ContinuityNoteRecorder {
    private(set) var transitionNotes: [String?] = []

    func recordTransition(_ note: String?) {
        transitionNotes.append(note)
    }
}

private actor GenerationStepRecorder {
    private(set) var steps: [String] = []

    func record(_ step: String) {
        steps.append(step)
    }
}

private actor ScriptSettingsRecorder {
    private(set) var settings: [AppSettings] = []

    func record(_ nextSettings: AppSettings) {
        settings.append(nextSettings)
    }
}

actor FakeTTSService: TTSService {
    private(set) var recordedSettings: [AppSettings] = []

    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        recordedSettings.append(settings)
        var wavData = Data(repeating: 0, count: 44)
        wavData.append(Data(repeating: 1, count: 4_800))
        let credentialLabel = settings.activeTTSCredentialSets.first?.label ?? ""
        let modelName = settings.activeTTSCredentialSets.first?.modelName ?? settings.geminiTTSModel
        return TTSResult(
            wavData: wavData,
            credentialSetLabelUsed: credentialLabel,
            modelUsed: modelName,
            didUseFallback: false
        )
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

actor ConditionalDelayTTSService: TTSService {
    private let delaysByToken: [String: UInt64]

    init(delaysByToken: [String: UInt64]) {
        self.delaysByToken = delaysByToken
    }

    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        let joinedText = dialogues.map(\.text).joined(separator: " ")
        for (token, delayNanoseconds) in delaysByToken where joinedText.contains(token) {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        var wavData = Data(repeating: 0, count: 44)
        wavData.append(Data(repeating: 1, count: 4_800))
        let credentialLabel = settings.activeTTSCredentialSets.first?.label ?? ""
        let modelName = settings.activeTTSCredentialSets.first?.modelName ?? settings.geminiTTSModel
        return TTSResult(
            wavData: wavData,
            credentialSetLabelUsed: credentialLabel,
            modelUsed: modelName,
            didUseFallback: false
        )
    }
}

actor SizedTTSService: TTSService {
    private let audioDurationSeconds: Double

    init(audioDurationSeconds: Double) {
        self.audioDurationSeconds = audioDurationSeconds
    }

    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        let audioByteCount = max(480, Int(audioDurationSeconds * Double(24_000 * 2)))
        var wavData = Data(repeating: 0, count: 44)
        wavData.append(Data(repeating: 1, count: audioByteCount))
        let credentialLabel = settings.activeTTSCredentialSets.first?.label ?? ""
        let modelName = settings.activeTTSCredentialSets.first?.modelName ?? settings.geminiTTSModel
        return TTSResult(
            wavData: wavData,
            credentialSetLabelUsed: credentialLabel,
            modelUsed: modelName,
            didUseFallback: false
        )
    }
}

actor FakeAudioPlaybackService: AudioPlaybackServiceProtocol {
    private(set) var playCount = 0
    private(set) var isPlaying = false

    func play(wavData: Data) async throws {
        playCount += 1
        isPlaying = true
        let wavDurationSeconds = max(0.01, Double(max(0, wavData.count - 44)) / Double(24_000 * 2))
        try await Task.sleep(nanoseconds: UInt64(wavDurationSeconds * 1_000_000_000))
        isPlaying = false
    }

    func stopPlayback() async {
        isPlaying = false
    }

    func pausePlayback() async {}

    func resumePlayback() async {}

    func fetchIsPlaying() async -> Bool { isPlaying }
}

actor FakeBedAudioPlaybackService: BedAudioPlaybackServiceProtocol {
    private(set) var prepareJingleCallCount = 0
    private(set) var playJingleCallCount = 0
    private(set) var startBedCallCount = 0
    private(set) var startBedDates: [Date] = []
    private(set) var fadeOutAndStopBedCallCount = 0
    private(set) var fadeOutAndStopBedDates: [Date] = []
    private(set) var stopCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var lastSettings: BGMSettings?
    private(set) var lastJinglePlacement: JinglePlacement?
    private var jingleDurationToReturn: Double = 0

    func setJingleDurationToReturn(_ duration: Double) {
        jingleDurationToReturn = duration
    }

    func prepareJingle(settings: BGMSettings, placement: JinglePlacement) async -> Double {
        prepareJingleCallCount += 1
        lastSettings = settings
        lastJinglePlacement = placement
        return jingleDurationToReturn
    }

    func playJingle(settings: BGMSettings, placement: JinglePlacement) async -> Double {
        playJingleCallCount += 1
        lastSettings = settings
        lastJinglePlacement = placement
        return jingleDurationToReturn
    }

    func startBed(settings: BGMSettings) async {
        startBedCallCount += 1
        startBedDates.append(Date())
        lastSettings = settings
    }

    func fadeOutAndStopBed(settings: BGMSettings) async {
        fadeOutAndStopBedCallCount += 1
        fadeOutAndStopBedDates.append(Date())
        lastSettings = settings
    }

    func stopPlayback() async {
        stopCallCount += 1
    }

    func pausePlayback() async {
        pauseCallCount += 1
    }

    func resumePlayback() async {
        resumeCallCount += 1
    }
}

actor FakeRecordingService: ShowRecordingServiceProtocol {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastOutputURL: URL?

    func startRecording(outputURL: URL) async throws {
        startCallCount += 1
        lastOutputURL = outputURL
    }

    func stopRecording() async throws {
        stopCallCount += 1
    }
}

actor FakePreGeneratedScriptStore: PreGeneratedScriptStoreProtocol {
    var session: PersistedScriptSession?
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0
    private(set) var clearCallCount = 0

    init(session: PersistedScriptSession? = nil) {
        self.session = session
    }

    func save(_ session: PersistedScriptSession) async {
        saveCallCount += 1
        self.session = session
    }

    func load() async -> PersistedScriptSession? {
        loadCallCount += 1
        return session
    }

    func clear() async {
        clearCallCount += 1
        session = nil
    }
}

struct FakeServiceFactory: AppServiceFactory {
    let musicService: FakeMusicService
    let musicPlaybackProfile: MusicPlaybackProfile
    let scriptService: FakeScriptGenerationService
    let ttsService: any TTSService
    let audioPlaybackService: any AudioPlaybackServiceProtocol
    let bedAudioPlaybackService: any BedAudioPlaybackServiceProtocol
    let recordingService: (any ShowRecordingServiceProtocol)?
    let scriptStore: any PreGeneratedScriptStoreProtocol
    let supportedServices: [MusicServiceKind]

    init(
        musicService: FakeMusicService,
        musicPlaybackProfile: MusicPlaybackProfile = MusicPlaybackProfile(),
        scriptService: FakeScriptGenerationService = FakeScriptGenerationService(),
        ttsService: any TTSService = FakeTTSService(),
        audioPlaybackService: any AudioPlaybackServiceProtocol = FakeAudioPlaybackService(),
        bedAudioPlaybackService: any BedAudioPlaybackServiceProtocol = FakeBedAudioPlaybackService(),
        recordingService: (any ShowRecordingServiceProtocol)? = nil,
        scriptStore: any PreGeneratedScriptStoreProtocol = FakePreGeneratedScriptStore(),
        supportedServices: [MusicServiceKind] = [.appleMusic, .youtubeMusic, .spotify]
    ) {
        self.musicService = musicService
        self.musicPlaybackProfile = musicPlaybackProfile
        self.scriptService = scriptService
        self.ttsService = ttsService
        self.audioPlaybackService = audioPlaybackService
        self.bedAudioPlaybackService = bedAudioPlaybackService
        self.recordingService = recordingService
        self.scriptStore = scriptStore
        self.supportedServices = supportedServices
    }

    func availableServices() -> [MusicServiceKind] { supportedServices }

    @MainActor func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService { musicService }

    func makeMusicPlaybackProfile(for serviceKind: MusicServiceKind) -> MusicPlaybackProfile { musicPlaybackProfile }

    func makeScriptService(settings: AppSettings, cueSheetLogger: ShowCueSheetLogger?) -> any ScriptGenerationService { scriptService }

    func makeTTSService(settings: AppSettings, cueSheetLogger: ShowCueSheetLogger?) -> any TTSService { ttsService }

    func makeAudioPlaybackService() -> any AudioPlaybackServiceProtocol { audioPlaybackService }

    func makeBedAudioPlaybackService() -> any BedAudioPlaybackServiceProtocol { bedAudioPlaybackService }

    func makeRecordingService() -> (any ShowRecordingServiceProtocol)? { recordingService }

    func makePreGeneratedScriptStore() -> any PreGeneratedScriptStoreProtocol { scriptStore }
}
