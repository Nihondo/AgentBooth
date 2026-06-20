import Foundation

/// ラジオ番組全体に共通する定数。
enum RadioConstants {
    /// プレイリストから使用する最大トラック数。
    static let maxTrackCount = 30
}

/// The supported music backends.
enum MusicServiceKind: String, CaseIterable, Codable, Identifiable {
    case appleMusic = "apple_music"
    case youtubeMusic = "youtube_music"
    case spotify = "spotify"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .youtubeMusic:
            return "YouTube Music"
        case .spotify:
            return "Spotify"
        }
    }
}

/// 音楽サービスごとの再生特性を表す設定。
struct MusicPlaybackProfile: Equatable, Sendable {
    /// 再生開始レイテンシを見込んで、トラック開始を前倒しする秒数。
    let startupLatencyCompensationSeconds: Double

    init(startupLatencyCompensationSeconds: Double = 0) {
        self.startupLatencyCompensationSeconds = startupLatencyCompensationSeconds
    }
}

/// The overlap strategy between music playback and generated narration.
enum OverlapMode: String, CaseIterable, Codable, Identifiable {
    case enabled
    case disabled

    var id: String { rawValue }

    static var orderedCases: [OverlapMode] {
        [
            .enabled,
            .disabled,
        ]
    }

    var displayName: String {
        switch self {
        case .enabled:
            return String(localized: "トークと曲を重ねる")
        case .disabled:
            return String(localized: "トークと曲を分ける")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.enabled.rawValue, "outro_over", "intro_over", "music_bed", "full_radio":
            self = .enabled
        case Self.disabled.rawValue, "sequential":
            self = .disabled
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown overlap mode: \(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 台本・TTS の生成タイミングモード。
enum ScriptGenerationMode: String, CaseIterable, Codable, Identifiable {
    /// 従来: 再生しながら1セグメントずつ先読み生成。
    case onDemand
    /// 新: 再生前に全台本を一括生成しレビュー後に再生。
    case preGenerate

    var id: String { rawValue }

    static var orderedCases: [ScriptGenerationMode] {
        [.onDemand, .preGenerate]
    }

    var displayName: String {
        switch self {
        case .onDemand:
            return String(localized: "オンデマンド生成")
        case .preGenerate:
            return String(localized: "事前生成（レビュー）")
        }
    }

    /// 後方互換: 未知値は `.onDemand` にフォールバック。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? Self.onDemand.rawValue
        self = ScriptGenerationMode(rawValue: raw) ?? .onDemand
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The current radio program phase.
enum RadioPhase: String, Codable {
    case idle
    case opening
    case intro
    case playing
    case outro
    case closing
    /// 事前生成モードでレビュー待ち中。
    case reviewing
}

/// The primary button state shown in the main window.
enum PrimaryControlState: Equatable {
    case start
    case pause
    case resume

    var buttonLabelText: String {
        switch self {
        case .start:
            return String(localized: "開始")
        case .pause:
            return String(localized: "一時停止")
        case .resume:
            return String(localized: "再開")
        }
    }

    var buttonSystemImageName: String {
        switch self {
        case .start:
            return "play.fill"
        case .pause:
            return "pause.fill"
        case .resume:
            return "play.fill"
        }
    }
}

/// The supported script generation CLI tools.
enum ScriptCLIKind: String, CaseIterable, Codable, Identifiable {
    case claude
    case gemini
    case codex
    case copilot
    case custom

    var id: String { rawValue }

    /// UI 表示用の名前。
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .custom: String(localized: "カスタム")
        }
    }
}

/// One music track from the selected service.
struct TrackInfo: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let playlistName: String
    let serviceID: String
    let artworkURL: String?

    init(
        name: String,
        artist: String,
        album: String,
        durationSeconds: Int = 0,
        playlistName: String = "",
        serviceID: String = "",
        artworkURL: String? = nil
    ) {
        self.name = name
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.playlistName = playlistName
        self.serviceID = serviceID
        self.artworkURL = artworkURL
    }

    var id: String {
        [playlistName, serviceID, name, artist, album].joined(separator: "|")
    }

    var displayText: String {
        "\(name) / \(artist)"
    }
}

/// The result of a TTS synthesis call, including which model was actually used.
struct TTSResult: Sendable {
    let wavData: Data
    let credentialSetLabelUsed: String
    let modelUsed: String
    let didUseFallback: Bool
}

/// One line in a generated conversation.
struct DialogueLine: Codable, Equatable, Sendable {
    let speaker: String
    var text: String
}

/// A generated radio segment script.
struct RadioScript: Codable, Equatable, Sendable {
    let segmentType: String
    var dialogues: [DialogueLine]
    let summaryBullets: [String]
    let track: TrackInfo?
}

/// User-selected voice names.
struct VoiceSettings: Codable, Equatable, Sendable {
    var maleVoiceName: String = "Charon"
    var femaleVoiceName: String = "Kore"
}

/// User-visible host names.
struct PersonalitySettings: Codable, Equatable, Sendable {
    var maleHostName: String = "田中"
    var femaleHostName: String = "佐藤"
}

/// 時刻から切り替える番組の時間帯。
enum TimeBand: String, Codable, CaseIterable, Identifiable, Sendable {
    case earlyMorning
    case morning
    case afternoon
    case evening
    case night
    case lateNight

    var id: String { rawValue }

    /// UI表示用の時間帯名。
    var displayName: String {
        switch self {
        case .earlyMorning:
            return String(localized: "早朝")
        case .morning:
            return String(localized: "朝")
        case .afternoon:
            return String(localized: "昼")
        case .evening:
            return String(localized: "夕方")
        case .night:
            return String(localized: "夜")
        case .lateNight:
            return String(localized: "深夜")
        }
    }

    /// UIに表示する時間帯の目安。
    var hourRangeDescription: String {
        switch self {
        case .earlyMorning:
            return "5:00-7:59"
        case .morning:
            return "8:00-11:59"
        case .afternoon:
            return "12:00-16:59"
        case .evening:
            return "17:00-19:59"
        case .night:
            return "20:00-23:59"
        case .lateNight:
            return "0:00-4:59"
        }
    }

    /// 指定日時をローカルカレンダー上の時間帯へ変換する。
    static func makeTimeBand(date: Date = Date(), calendar: Calendar = .current) -> TimeBand {
        makeTimeBand(hour: calendar.component(.hour, from: date))
    }

    /// 0〜23時の値を時間帯へ変換する。
    static func makeTimeBand(hour: Int) -> TimeBand {
        switch hour {
        case 0..<5:
            return .lateNight
        case 5..<8:
            return .earlyMorning
        case 8..<12:
            return .morning
        case 12..<17:
            return .afternoon
        case 17..<20:
            return .evening
        case 20..<24:
            return .night
        default:
            return .morning
        }
    }
}

/// シーン・話し方などのディレクション設定。
struct DirectionSettings: Codable, Equatable, Sendable {
    /// TTS 向け演技指示（声のトーン・話し方）。
    var sceneDirection: String = ""
    /// スクリプト生成向けコンテンツ指示（話題・テーマ・内容の方向性）。
    var scriptDirection: String = ""
    var timeBasedPresets: [TimeBand: String] = [:]

    enum CodingKeys: String, CodingKey {
        case sceneDirection, scriptDirection, timeBasedPresets
    }

    init(
        sceneDirection: String = "",
        scriptDirection: String = "",
        timeBasedPresets: [TimeBand: String] = [:]
    ) {
        self.sceneDirection = sceneDirection
        self.scriptDirection = scriptDirection
        self.timeBasedPresets = timeBasedPresets
    }

    /// 旧バージョンの設定JSONに新フィールドがなくても既定値で復元する。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneDirection = try c.decodeIfPresent(String.self, forKey: .sceneDirection) ?? ""
        scriptDirection = try c.decodeIfPresent(String.self, forKey: .scriptDirection) ?? ""
        timeBasedPresets = try c.decodeIfPresent([TimeBand: String].self, forKey: .timeBasedPresets) ?? [:]
    }
}

/// Playback volume tuning.
struct VolumeSettings: Codable, Equatable, Sendable {
    var normalVolume: Int = 100
    var talkVolume: Int = 25
    var fadeDuration: Double = 1.5
    var fadeEarlySeconds: Int = 15
    var musicLeadSeconds: Double = 10.0
    /// 最大再生秒数。0 の場合は制限なし（曲をフルで再生）。
    var maxPlaybackDurationSeconds: Int = 0

    enum CodingKeys: String, CodingKey {
        case normalVolume, talkVolume, fadeDuration, fadeEarlySeconds, musicLeadSeconds, maxPlaybackDurationSeconds
    }

    init(
        normalVolume: Int = 100,
        talkVolume: Int = 25,
        fadeDuration: Double = 5.0,
        fadeEarlySeconds: Int = 10,
        musicLeadSeconds: Double = 10.0,
        maxPlaybackDurationSeconds: Int = 0
    ) {
        self.normalVolume = normalVolume
        self.talkVolume = talkVolume
        self.fadeDuration = fadeDuration
        self.fadeEarlySeconds = fadeEarlySeconds
        self.musicLeadSeconds = musicLeadSeconds
        self.maxPlaybackDurationSeconds = maxPlaybackDurationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        normalVolume = try container.decodeIfPresent(Int.self, forKey: .normalVolume) ?? 100
        talkVolume = try container.decodeIfPresent(Int.self, forKey: .talkVolume) ?? 25
        fadeDuration = try container.decodeIfPresent(Double.self, forKey: .fadeDuration) ?? 5.0
        fadeEarlySeconds = try container.decodeIfPresent(Int.self, forKey: .fadeEarlySeconds) ?? 10
        musicLeadSeconds = try container.decodeIfPresent(Double.self, forKey: .musicLeadSeconds) ?? 10.0
        maxPlaybackDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .maxPlaybackDurationSeconds) ?? 0
    }
}

/// BGM / ジングルの音源指定種別。
enum AudioAssetSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case file
    case directory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .file:
            return String(localized: "ファイル")
        case .directory:
            return String(localized: "ディレクトリ")
        }
    }
}

/// BGM / ジングルの音源指定。
struct AudioAssetSource: Codable, Equatable, Sendable {
    var kind: AudioAssetSourceKind = .file
    var path: String = ""
}

/// トーク中に重ねるベッド BGM とジングルの設定。
struct BGMSettings: Codable, Equatable, Sendable {
    var isBedEnabled: Bool = false
    var isOpeningJingleEnabled: Bool = false
    var isClosingJingleEnabled: Bool = false
    var bedAudioSource: AudioAssetSource = .init()
    var openingJingleSource: AudioAssetSource = .init()
    var closingJingleSource: AudioAssetSource = .init()
    var bedVolume: Double = 0.18
    var jingleVolume: Double = 0.7
    var bedFadeInDuration: Double = 0.5
    var bedFadeOutDuration: Double = 1.2
}

/// Optional radio show metadata.
struct RadioShowSettings: Codable, Equatable, Sendable {
    var showName: String = ""
    var frequency: String = ""
    var locationName: String?
}

/// 番組のトーンと再生バランスをまとめて切り替えるプロフィール。
struct ShowProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var radioShowSettings: RadioShowSettings = .init()
    var personalitySettings: PersonalitySettings = .init()
    var directionSettings: DirectionSettings = .init()
    var voiceSettings: VoiceSettings = .init()
    var volumeSettings: VolumeSettings = .init()
    var bgmSettings: BGMSettings = .init()
    var defaultOverlapMode: OverlapMode = .enabled
    var defaultScriptGenerationMode: ScriptGenerationMode = .onDemand
}

/// Gemini TTS の「API キー + モデル」1組。
struct TTSCredentialSet: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var label: String = ""
    var apiKey: String = ""
    var modelName: String = "gemini-2.5-flash-preview-tts"
}

/// Application-wide persisted settings snapshot.
struct AppSettings: Codable, Equatable, Sendable {
    var geminiAPIKey: String = ""
    var geminiTTSModel: String = "gemini-2.5-flash-preview-tts"
    var geminiTTSFallbackModel: String = "gemini-2.5-pro-preview-tts"
    var ttsCredentialSets: [TTSCredentialSet] = []
    var scriptCLIKind: ScriptCLIKind = .claude
    var scriptCLIModel: String = ""
    var defaultMusicService: MusicServiceKind = .appleMusic
    var activeProfileId: UUID?
    var defaultOverlapMode: OverlapMode = .enabled
    var defaultScriptGenerationMode: ScriptGenerationMode = .onDemand
    var voiceSettings: VoiceSettings = .init()
    var personalitySettings: PersonalitySettings = .init()
    var directionSettings: DirectionSettings = .init()
    var volumeSettings: VolumeSettings = .init()
    var bgmSettings: BGMSettings = .init()
    var radioShowSettings: RadioShowSettings = .init()
    var isRecordingEnabled: Bool = false
    var recordingOutputDirectory: String = ""
    var youtubeMusicUserAgent: String = defaultYouTubeMusicUserAgent
    /// カスタム CLI の実行ファイル名またはフルパス。scriptCLIKind == .custom のときに使用。
    var customCLIExecutable: String = ""
    /// カスタム CLI に常時渡す引数配列。`{prompt}` をプロンプト文字列に置換。
    var customCLIArguments: [String] = []
    /// scriptCLIModel が非空の場合のみ末尾に追加される引数配列。`{model}` をモデル名に置換。
    var customCLIModelArguments: [String] = []

    enum CodingKeys: String, CodingKey {
        case geminiAPIKey, geminiTTSModel, geminiTTSFallbackModel, ttsCredentialSets
        case scriptCLIKind, scriptCLIModel
        case defaultMusicService, activeProfileId, defaultOverlapMode, defaultScriptGenerationMode
        case voiceSettings, personalitySettings, directionSettings, volumeSettings, bgmSettings, radioShowSettings
        case isRecordingEnabled, recordingOutputDirectory, youtubeMusicUserAgent
        case customCLIExecutable, customCLIArguments, customCLIModelArguments
    }

    /// 実際に TTS 呼び出し対象となる有効セットのみ返す。
    var activeTTSCredentialSets: [TTSCredentialSet] {
        ttsCredentialSets.filter { !$0.apiKey.isEmpty && !$0.modelName.isEmpty }
    }
}

extension AppSettings {
    /// フィールドを `decodeIfPresent` で読むことで、旧バージョンの JSON から安全にデコードできる。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        geminiAPIKey = try c.decodeIfPresent(String.self, forKey: .geminiAPIKey) ?? ""
        geminiTTSModel = try c.decodeIfPresent(String.self, forKey: .geminiTTSModel) ?? "gemini-2.5-flash-preview-tts"
        geminiTTSFallbackModel = try c.decodeIfPresent(String.self, forKey: .geminiTTSFallbackModel) ?? "gemini-2.5-pro-preview-tts"
        ttsCredentialSets = try c.decodeIfPresent([TTSCredentialSet].self, forKey: .ttsCredentialSets) ?? []
        scriptCLIKind = try c.decodeIfPresent(ScriptCLIKind.self, forKey: .scriptCLIKind) ?? .claude
        scriptCLIModel = try c.decodeIfPresent(String.self, forKey: .scriptCLIModel) ?? ""
        defaultMusicService = try c.decodeIfPresent(MusicServiceKind.self, forKey: .defaultMusicService) ?? .appleMusic
        activeProfileId = try c.decodeIfPresent(UUID.self, forKey: .activeProfileId)
        defaultOverlapMode = try c.decodeIfPresent(OverlapMode.self, forKey: .defaultOverlapMode) ?? .enabled
        defaultScriptGenerationMode = try c.decodeIfPresent(ScriptGenerationMode.self, forKey: .defaultScriptGenerationMode) ?? .onDemand
        voiceSettings = try c.decodeIfPresent(VoiceSettings.self, forKey: .voiceSettings) ?? .init()
        personalitySettings = try c.decodeIfPresent(PersonalitySettings.self, forKey: .personalitySettings) ?? .init()
        directionSettings = try c.decodeIfPresent(DirectionSettings.self, forKey: .directionSettings) ?? .init()
        volumeSettings = try c.decodeIfPresent(VolumeSettings.self, forKey: .volumeSettings) ?? .init()
        bgmSettings = try c.decodeIfPresent(BGMSettings.self, forKey: .bgmSettings) ?? .init()
        radioShowSettings = try c.decodeIfPresent(RadioShowSettings.self, forKey: .radioShowSettings) ?? .init()
        isRecordingEnabled = try c.decodeIfPresent(Bool.self, forKey: .isRecordingEnabled) ?? false
        recordingOutputDirectory = try c.decodeIfPresent(String.self, forKey: .recordingOutputDirectory) ?? ""
        youtubeMusicUserAgent = try c.decodeIfPresent(String.self, forKey: .youtubeMusicUserAgent) ?? defaultYouTubeMusicUserAgent
        customCLIExecutable = try c.decodeIfPresent(String.self, forKey: .customCLIExecutable) ?? ""
        customCLIArguments = try c.decodeIfPresent([String].self, forKey: .customCLIArguments) ?? []
        customCLIModelArguments = try c.decodeIfPresent([String].self, forKey: .customCLIModelArguments) ?? []
    }
}

extension ShowProfile {
    /// 既存の設定スナップショットからプロフィール対象フィールドだけを取り出す。
    init(id: UUID = UUID(), name: String, settings: AppSettings) {
        self.id = id
        self.name = name
        radioShowSettings = settings.radioShowSettings
        personalitySettings = settings.personalitySettings
        directionSettings = settings.directionSettings
        voiceSettings = settings.voiceSettings
        volumeSettings = settings.volumeSettings
        bgmSettings = settings.bgmSettings
        defaultOverlapMode = settings.defaultOverlapMode
        defaultScriptGenerationMode = settings.defaultScriptGenerationMode
    }
}

extension AppSettings {
    /// アプリ全体設定にプロフィール対象フィールドを重ねる。
    func applyingProfile(_ profile: ShowProfile) -> AppSettings {
        var settings = self
        settings.activeProfileId = profile.id
        settings.defaultOverlapMode = profile.defaultOverlapMode
        settings.defaultScriptGenerationMode = profile.defaultScriptGenerationMode
        settings.voiceSettings = profile.voiceSettings
        settings.personalitySettings = profile.personalitySettings
        settings.directionSettings = profile.directionSettings
        settings.volumeSettings = profile.volumeSettings
        settings.bgmSettings = profile.bgmSettings
        settings.radioShowSettings = profile.radioShowSettings
        return settings
    }
}

/// プレイリストのトラック一覧取得状態
enum TrackListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([TrackInfo])
    case failed(String)
}

/// The current UI-facing radio session state.
struct RadioState: Equatable, Sendable {
    var isRunning: Bool = false
    var isPaused: Bool = false
    var phase: RadioPhase = .idle
    var currentTrack: TrackInfo?
    var playlistName: String = ""
    var upcomingTracks: [TrackInfo] = []
    var volume: Int = 100
    var overlapMode: OverlapMode = .enabled
    var errorMessage: String?
    var statusMessage: String = ""
    var isProcessing: Bool = false
    var isRecording: Bool = false
    var recordingOutputURL: URL?
    var trackIndex: Int = 0
    var playlistTrackCount: Int = 0
    /// 音楽サービスから取得した現在の再生位置（秒）
    var currentPlaybackPosition: Double = 0

    var primaryControlState: PrimaryControlState {
        if isPaused {
            return .resume
        }
        if isRunning {
            return .pause
        }
        return .start
    }
}

/// 事前生成モードのレビュー画面で1セグメント分の台本と TTS 入力を提示する構造体。
struct ReviewScriptItem: Identifiable, Equatable, Sendable {
    let id: Int
    let segmentLabel: String
    /// 会話台本（編集可能）。
    var script: RadioScript
    /// 発話指示（time-band 合成後の実効値、編集可能）。
    var sceneDirection: String
    /// 男性パーソナリティの音声名（表示用・読取専用）。
    let maleVoiceName: String
    /// 女性パーソナリティの音声名（表示用・読取専用）。
    let femaleVoiceName: String
}
