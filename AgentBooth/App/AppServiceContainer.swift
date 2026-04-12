import Foundation

struct LiveAppServiceFactory: AppServiceFactory {
    func availableServices() -> [MusicServiceKind] {
        [.appleMusic]
    }

    func makeMusicService(for serviceKind: MusicServiceKind) -> any MusicService {
        switch serviceKind {
        case .appleMusic:
            return AppleMusicService()
        case .youtubeMusic:
            return YouTubeMusicPlaceholderService()
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
}
