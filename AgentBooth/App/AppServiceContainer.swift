import Foundation

struct LiveAppServiceFactory: AppServiceFactory {
    private let spotifyStartupLatencyCompensationSeconds = 0.35

    func availableServices() -> [MusicServiceKind] {
        [.appleMusic, .youtubeMusic, .spotify]
    }

    /// YouTube Music 用 WebViewStore はシングルトンで保持（WKWebView インスタンスを共有）。
    /// @MainActor static let で初期化を MainActor に限定する。
    @MainActor static let sharedYouTubeMusicStore = YouTubeMusicWebViewStore()
    /// Spotify 用 WebViewStore はシングルトンで保持（WKWebView インスタンスを共有）。
    @MainActor static let sharedSpotifyStore = SpotifyWebViewStore()

    @MainActor
    func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService {
        switch serviceKind {
        case .appleMusic:
            return AppleMusicService()
        case .youtubeMusic:
            return YouTubeMusicService(store: LiveAppServiceFactory.sharedYouTubeMusicStore)
        case .spotify:
            return SpotifyMusicService(store: LiveAppServiceFactory.sharedSpotifyStore)
        }
    }

    func makeMusicPlaybackProfile(for serviceKind: MusicServiceKind) -> MusicPlaybackProfile {
        switch serviceKind {
        case .appleMusic, .youtubeMusic:
            return MusicPlaybackProfile()
        case .spotify:
            return MusicPlaybackProfile(
                startupLatencyCompensationSeconds: spotifyStartupLatencyCompensationSeconds
            )
        }
    }

    func makeScriptService(settings: AppSettings, cueSheetLogger: ShowCueSheetLogger?) -> any ScriptGenerationService {
        ProcessScriptGenerationService(cueSheetLogger: cueSheetLogger)
    }

    func makeTTSService(settings: AppSettings, cueSheetLogger: ShowCueSheetLogger?) -> any TTSService {
        GeminiTTSService(cueSheetLogger: cueSheetLogger)
    }

    func makeAudioPlaybackService() -> any AudioPlaybackServiceProtocol {
        SystemAudioPlaybackService()
    }

    func makeRecordingService() -> (any ShowRecordingServiceProtocol)? {
        SystemAudioCaptureService()
    }
}
