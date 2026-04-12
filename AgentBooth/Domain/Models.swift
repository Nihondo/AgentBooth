import Foundation

/// The supported music backends.
enum MusicServiceKind: String, CaseIterable, Codable, Identifiable {
    case appleMusic = "apple_music"
    case youtubeMusic = "youtube_music"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .youtubeMusic:
            return "YouTube Music"
        }
    }
}

/// The overlap strategy between music playback and generated narration.
enum OverlapMode: String, CaseIterable, Codable, Identifiable {
    case sequential
    case outroOver = "outro_over"
    case introOver = "intro_over"
    case musicBed = "music_bed"
    case fullRadio = "full_radio"

    var id: String { rawValue }

    static var orderedCases: [OverlapMode] {
        [
            .fullRadio,
            .musicBed,
            .introOver,
            .outroOver,
            .sequential
        ]
    }

    var displayName: String {
        switch self {
        case .fullRadio:
            return "ラジオ風に自然に重ねる"
        case .musicBed:
            return "BGM を流しながらトークする"
        case .introOver:
            return "曲のイントロにトークを重ねる"
        case .outroOver:
            return "曲のアウトロにトークを重ねる"
        case .sequential:
            return "曲とトークを完全に分ける"
        }
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
}

/// The primary button state shown in the main window.
enum PrimaryControlState: Equatable {
    case start
    case pause
    case resume

    var buttonLabelText: String {
        switch self {
        case .start:
            return "開始"
        case .pause:
            return "一時停止"
        case .resume:
            return "再開"
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

    var id: String { rawValue }
}

/// One music track from the selected service.
struct TrackInfo: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let playlistName: String
    let serviceID: String

    init(
        name: String,
        artist: String,
        album: String,
        durationSeconds: Int = 0,
        playlistName: String = "",
        serviceID: String = ""
    ) {
        self.name = name
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.playlistName = playlistName
        self.serviceID = serviceID
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
    let modelUsed: String
}

/// One line in a generated conversation.
struct DialogueLine: Codable, Equatable, Sendable {
    let speaker: String
    let text: String
}

/// A generated radio segment script.
struct RadioScript: Codable, Equatable, Sendable {
    let segmentType: String
    let dialogues: [DialogueLine]
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

/// Optional radio show metadata.
struct RadioShowSettings: Codable, Equatable, Sendable {
    var showName: String = ""
    var frequency: String = ""
}

/// Application-wide persisted settings snapshot.
struct AppSettings: Codable, Equatable, Sendable {
    var geminiAPIKey: String = ""
    var geminiTTSModel: String = "gemini-2.5-flash-preview-tts"
    var geminiTTSFallbackModel: String = "gemini-2.5-pro-preview-tts"
    var scriptCLIKind: ScriptCLIKind = .claude
    var scriptCLIModel: String = ""
    var defaultMusicService: MusicServiceKind = .appleMusic
    var defaultOverlapMode: OverlapMode = .fullRadio
    var voiceSettings: VoiceSettings = .init()
    var personalitySettings: PersonalitySettings = .init()
    var volumeSettings: VolumeSettings = .init()
    var radioShowSettings: RadioShowSettings = .init()
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
    var overlapMode: OverlapMode = .fullRadio
    var errorMessage: String?
    var statusMessage: String = ""

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
