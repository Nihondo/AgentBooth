import Foundation

/// A music backend that can list playlists and control playback.
protocol MusicService: Sendable {
    var serviceKind: MusicServiceKind { get }
    func fetchPlaylists() async throws -> [String]
    func fetchTracks(in playlistName: String) async throws -> [TrackInfo]
    func play(track: TrackInfo) async throws
    func stopPlayback() async
    func pausePlayback() async
    func resumePlayback() async
    func setVolume(level: Int) async
    func fetchVolume() async -> Int
    func fetchCurrentTrack() async throws -> TrackInfo?
    func fetchIsPlaying() async -> Bool
}

/// A script generator used for radio segment creation.
protocol ScriptGenerationService: Sendable {
    func generateOpening(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript
    func generateIntro(track: TrackInfo, settings: AppSettings, continuityNote: String?) async throws -> RadioScript
    func generateTransition(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        settings: AppSettings,
        continuityNote: String?
    ) async throws -> RadioScript
    func generateClosing(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript
}

/// A text-to-speech service that returns WAV bytes along with the model used.
protocol TTSService: Sendable {
    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult
}

/// An audio playback service used for generated WAV content.
protocol AudioPlaybackServiceProtocol: Sendable {
    func play(wavData: Data) async throws
    func stopPlayback() async
    func pausePlayback() async
    func resumePlayback() async
    func fetchIsPlaying() async -> Bool
}

/// A factory that wires live or fake services together.
protocol AppServiceFactory: Sendable {
    func availableServices() -> [MusicServiceKind]
    func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService
    func makeScriptService(settings: AppSettings) -> any ScriptGenerationService
    func makeTTSService(settings: AppSettings) -> any TTSService
    func makeAudioPlaybackService() -> any AudioPlaybackServiceProtocol
}
