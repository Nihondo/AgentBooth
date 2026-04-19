import CoreGraphics
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var availableServices: [MusicServiceKind]
    @Published var availablePlaylists: [String] = []
    @Published var selectedService: MusicServiceKind
    @Published var selectedPlaylistName: String = ""
    @Published private(set) var radioState = RadioState()
    @Published private(set) var isRecordingSession = false
    @Published private(set) var previewTrackListState: TrackListState = .idle

    private let settingsStore: AppSettingsStore
    private let serviceFactory: AppServiceFactory
    private var radioOrchestrator: RadioOrchestrator?
    private var shouldRecordOnNextStart = false

    init(settingsStore: AppSettingsStore, serviceFactory: AppServiceFactory) {
        self.settingsStore = settingsStore
        self.serviceFactory = serviceFactory
        let currentSettings = settingsStore.currentSettings
        self.availableServices = serviceFactory.availableServices()
        self.selectedService = currentSettings.defaultMusicService

        if !availableServices.contains(selectedService), let firstService = availableServices.first {
            self.selectedService = firstService
        }
    }

    var primaryControlState: PrimaryControlState {
        radioState.primaryControlState
    }

    var canStart: Bool {
        !selectedPlaylistName.isEmpty && !radioState.isRunning
    }

    var canShuffle: Bool {
        guard !radioState.isRunning else { return false }
        if case .loaded = previewTrackListState { return true }
        return false
    }

    /// トラックリストに表示するトラック一覧（実行中はラジオ状態、停止中はプレビュー）
    var displayTracks: [TrackInfo] {
        if radioState.isRunning, !radioState.upcomingTracks.isEmpty {
            return radioState.upcomingTracks
        }
        if case .loaded(let tracks) = previewTrackListState {
            return tracks
        }
        return []
    }

    /// 現在再生中のトラックID（ハイライト用）
    var currentPlayingTrackID: String? {
        radioState.isRunning ? radioState.currentTrack?.id : nil
    }

    /// 録音を有効にしたうえで番組を開始する
    func startShowWithRecording() {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            radioState.errorMessage = String(localized: "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で AgentBooth を許可してください。")
            return
        }
        shouldRecordOnNextStart = true
        isRecordingSession = true
        Task {
            await startShow(recordingRequested: true)
        }
    }

    func loadPlaylists() async {
        do {
            let musicService = serviceFactory.makeMusicService(for: selectedService)
            let playlists = try await musicService.fetchPlaylists()
            availablePlaylists = playlists
            if !playlists.contains(selectedPlaylistName) {
                selectedPlaylistName = playlists.first ?? ""
            }
            radioState.errorMessage = nil
        } catch {
            availablePlaylists = []
            selectedPlaylistName = ""
            radioState.errorMessage = error.localizedDescription
        }
    }

    func selectService(_ serviceKind: MusicServiceKind) {
        selectedService = serviceKind
        availablePlaylists = []
        selectedPlaylistName = ""
        Task {
            await loadPlaylists()
        }
    }

    func shufflePreviewTracks() {
        guard case .loaded(let tracks) = previewTrackListState else { return }
        previewTrackListState = .loaded(tracks.shuffled())
    }

    func selectPlaylist(_ playlistName: String) {
        selectedPlaylistName = playlistName
        previewTrackListState = .idle
        guard !playlistName.isEmpty else { return }
        previewTrackListState = .loading
        Task {
            await loadPreviewTracks(for: playlistName)
        }
    }

    private func loadPreviewTracks(for playlistName: String) async {
        do {
            let musicService = serviceFactory.makeMusicService(for: selectedService)
            let allTracks = try await musicService.fetchTracks(in: playlistName)
            let tracks = Array(allTracks.prefix(RadioConstants.maxTrackCount))
            guard selectedPlaylistName == playlistName else { return }
            previewTrackListState = .loaded(tracks)
        } catch {
            guard selectedPlaylistName == playlistName else { return }
            previewTrackListState = .failed(error.localizedDescription)
        }
    }

    func handlePrimaryControl(isTestMode: Bool = false) {
        switch primaryControlState {
        case .start:
            Task {
                if isTestMode {
                    await startShow(testMode: true)
                } else {
                    await startShow()
                }
            }
        case .pause:
            Task {
                await radioOrchestrator?.pauseShow()
            }
        case .resume:
            Task {
                await radioOrchestrator?.resumeShow()
            }
        }
    }

    func stopShow() {
        Task {
            await radioOrchestrator?.stopShow()
            radioOrchestrator = nil
        }
    }

    private func startShow(testMode: Bool = false, recordingRequested: Bool = false) async {
        guard !selectedPlaylistName.isEmpty else {
            shouldRecordOnNextStart = false
            isRecordingSession = false
            radioState.errorMessage = String(localized: "プレイリストを選択してください。")
            return
        }

        let currentSettings = settingsStore.currentSettings
        let cueSheetLogger = ShowCueSheetLogger()
        let musicService = serviceFactory.makeMusicService(for: selectedService)
        let musicPlaybackProfile = serviceFactory.makeMusicPlaybackProfile(for: selectedService)
        let scriptService: any ScriptGenerationService = testMode
            ? TestModeScriptGenerationService()
            : serviceFactory.makeScriptService(settings: currentSettings, cueSheetLogger: cueSheetLogger)
        let ttsService: any TTSService = testMode
            ? TestModeTTSService()
            : serviceFactory.makeTTSService(settings: currentSettings, cueSheetLogger: cueSheetLogger)
        let audioPlaybackService: any AudioPlaybackServiceProtocol = testMode
            ? TestModeAudioPlaybackService()
            : serviceFactory.makeAudioPlaybackService()
        let shouldRecord = recordingRequested || shouldRecordOnNextStart
        shouldRecordOnNextStart = false
        let recordingService = shouldRecord ? serviceFactory.makeRecordingService() : nil

        let orchestrator = RadioOrchestrator(
            settings: currentSettings,
            musicService: musicService,
            musicPlaybackProfile: musicPlaybackProfile,
            scriptService: scriptService,
            ttsService: ttsService,
            audioPlaybackService: audioPlaybackService,
            recordingService: recordingService,
            cueSheetLogger: cueSheetLogger
        ) { [weak self] nextState in
            Task { @MainActor [weak self] in
                self?.radioState = nextState
                if !nextState.isRunning {
                    self?.radioOrchestrator = nil
                    self?.isRecordingSession = false
                }
            }
        }

        let shuffledTracks: [TrackInfo]?
        if case .loaded(let tracks) = previewTrackListState {
            shuffledTracks = tracks
        } else {
            shuffledTracks = nil
        }

        radioOrchestrator = orchestrator
        await orchestrator.startShow(playlistName: selectedPlaylistName, initialTracks: shuffledTracks)
    }
}
