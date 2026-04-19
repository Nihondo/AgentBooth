import Foundation

/// A music backend that can list playlists and control playback.
protocol MusicService: Sendable {
    func fetchPlaylists() async throws -> [String]
    func fetchTracks(in playlistName: String) async throws -> [TrackInfo]
    /// 指定トラックの先頭から再生を開始する。
    func play(track: TrackInfo) async throws
    func stopPlayback() async
    func pausePlayback() async
    func resumePlayback() async
    func setVolume(level: Int) async
    func fetchVolume() async -> Int
    /// 現在再生中のトラック情報を返す。UI や診断用途のため維持している。
    func fetchCurrentTrack() async throws -> TrackInfo?
    /// 現在再生中かを返す。UI や診断用途のため維持している。
    func fetchIsPlaying() async -> Bool
    /// 現在の再生位置を秒単位で返す。
    func fetchPlaybackPosition() async -> Double
    /// 指定秒数へシークする。
    func seekToPosition(_ seconds: Double) async
}

/// A script generator used for radio segment creation.
protocol ScriptGenerationService: Sendable {
    func generateOpening(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript
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

/// A recording service that captures system audio during a show.
protocol ShowRecordingServiceProtocol: Sendable {
    func startRecording(outputURL: URL) async throws
    func stopRecording() async throws
}

/// A factory that wires live or fake services together.
protocol AppServiceFactory: Sendable {
    func availableServices() -> [MusicServiceKind]
    @MainActor func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService
    func makeMusicPlaybackProfile(for serviceKind: MusicServiceKind) -> MusicPlaybackProfile
    func makeScriptService(settings: AppSettings, cueSheetLogger: ShowCueSheetLogger?) -> any ScriptGenerationService
    func makeTTSService(settings: AppSettings, cueSheetLogger: ShowCueSheetLogger?) -> any TTSService
    func makeAudioPlaybackService() -> any AudioPlaybackServiceProtocol
    func makeRecordingService() -> (any ShowRecordingServiceProtocol)?
}
