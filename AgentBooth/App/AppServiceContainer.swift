import Foundation

struct LiveAppServiceFactory: AppServiceFactory {
    func availableServices() -> [MusicServiceKind] {
        [.appleMusic, .youtubeMusic]
    }

    /// YouTube Music 用 WebViewStore はシングルトンで保持（WKWebView インスタンスを共有）。
    /// @MainActor static let で初期化を MainActor に限定する。
    @MainActor static let sharedYouTubeMusicStore = YouTubeMusicWebViewStore()

    @MainActor
    func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService {
        switch serviceKind {
        case .appleMusic:
            return AppleMusicService()
        case .youtubeMusic:
            return YouTubeMusicService(store: LiveAppServiceFactory.sharedYouTubeMusicStore)
        }
    }

    func makeScriptService(settings: AppSettings) -> any ScriptGenerationService {
        ProcessScriptGenerationService()
    }

    func makeTTSService(settings: AppSettings) -> any TTSService {
        GeminiTTSService()
    }

    func makeAudioPlaybackService() -> any AudioPlaybackServiceProtocol {
        SystemAudioPlaybackService()
    }

    func makeRecordingService() -> (any ShowRecordingServiceProtocol)? {
        SystemAudioCaptureService()
    }
}
