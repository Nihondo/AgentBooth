import Combine
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
    @Published private(set) var showProfiles: [ShowProfile]
    @Published private(set) var activeProfileId: UUID?
    /// 事前生成モードのレビュー用 ViewModel。ドラフト編集状態はここが所有し、
    /// `MainViewModel` 自体は打鍵のたびに publish されない（キャレット保護のため）。
    /// レビューウィンドウを閉じても nil にはならず、編集内容は保持されたまま番組は中断状態を維持する。
    @Published private(set) var reviewViewModel: ScriptReviewViewModel?
    /// レビューウィンドウを開くべきかどうかの表示フラグ（`ContentView` が openWindow/dismissWindow のトリガに使う）。
    @Published var isReviewing = false
    /// 保存済み事前生成台本の再利用確認 alert の表示フラグ。
    @Published var isReusePrompting = false

    private let settingsStore: AppSettingsStore
    private let serviceFactory: AppServiceFactory
    private var radioOrchestrator: RadioOrchestrator?
    private var shouldRecordOnNextStart = false
    private var settingsCancellables: Set<AnyCancellable> = []

    init(settingsStore: AppSettingsStore, serviceFactory: AppServiceFactory) {
        self.settingsStore = settingsStore
        self.serviceFactory = serviceFactory
        let currentSettings = settingsStore.currentSettings
        self.availableServices = serviceFactory.availableServices()
        self.selectedService = currentSettings.defaultMusicService
        self.showProfiles = settingsStore.showProfiles
        self.activeProfileId = currentSettings.activeProfileId

        if !availableServices.contains(selectedService), let firstService = availableServices.first {
            self.selectedService = firstService
        }

        settingsStore.$showProfiles
            .sink { [weak self] profiles in
                self?.showProfiles = profiles
            }
            .store(in: &settingsCancellables)

        settingsStore.$currentSettings
            .sink { [weak self] settings in
                self?.activeProfileId = settings.activeProfileId
            }
            .store(in: &settingsCancellables)
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

    func selectProfile(_ profileID: UUID) {
        guard !radioState.isRunning else { return }
        do {
            try settingsStore.selectProfile(profileID)
        } catch {
            radioState.errorMessage = error.localizedDescription
        }
    }

    /// 録音を有効にしたうえで番組を開始する
    func startShowWithRecording(isTestMode: Bool = false) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            radioState.errorMessage = String(localized: "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で AgentBooth を許可してください。")
            return
        }
        shouldRecordOnNextStart = true
        isRecordingSession = true
        Task {
            await startShow(testMode: isTestMode, recordingRequested: true)
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
        let bedAudioPlaybackService: any BedAudioPlaybackServiceProtocol = testMode
            ? TestModeBedAudioPlaybackService()
            : serviceFactory.makeBedAudioPlaybackService()
        let scriptStore = serviceFactory.makePreGeneratedScriptStore()
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
            bedAudioPlaybackService: bedAudioPlaybackService,
            recordingService: recordingService,
            cueSheetLogger: cueSheetLogger,
            scriptStore: scriptStore,
            reviewDidBecomeAvailable: { [weak self] items in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reviewViewModel = ScriptReviewViewModel(
                        items: items,
                        settingsStore: self.settingsStore,
                        serviceFactory: self.serviceFactory,
                        isTestMode: testMode
                    )
                    self.isReviewing = true
                }
            },
            reusePromptDidBecomeAvailable: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isReusePrompting = true
                }
            }
        ) { [weak self] nextState in
            Task { @MainActor [weak self] in
                self?.radioState = nextState
                if !nextState.isRunning {
                    self?.radioOrchestrator = nil
                    self?.isRecordingSession = false
                    self?.isReusePrompting = false
                    // レビュー中に Stop ボタン等で番組そのものが停止した場合はレビューも畳む。
                    self?.isReviewing = false
                    self?.reviewViewModel = nil
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

    // MARK: - 台本レビュー

    /// レビュー済みの台本を承認して再生を開始する。
    func approveScriptReview() {
        guard let reviewViewModel else { return }
        let items = reviewViewModel.makeApprovedItems()
        isReviewing = false
        self.reviewViewModel = nil
        Task { await radioOrchestrator?.approveScripts(items) }
    }

    /// レビューをキャンセルして番組を停止する。
    func cancelScriptReview() {
        isReviewing = false
        reviewViewModel = nil
        Task { await radioOrchestrator?.cancelReview() }
    }

    /// 保存済み台本を再利用してレビューへ進む。
    func confirmReuse() {
        isReusePrompting = false
        Task { await radioOrchestrator?.confirmReuse() }
    }

    /// 保存済み台本を再利用対象から外して再生成する。
    func declineReuse() {
        isReusePrompting = false
        Task { await radioOrchestrator?.declineReuse() }
    }
}
