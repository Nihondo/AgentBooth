import Foundation

enum AppleMusicServiceError: LocalizedError {
    case unsupportedService

    var errorDescription: String? {
        switch self {
        case .unsupportedService:
            return "この音楽サービスは未実装です。"
        }
    }
}

/// Controls Music.app via AppleScript.
final class AppleMusicService: @unchecked Sendable, MusicService {
    let serviceKind: MusicServiceKind = .appleMusic

    private let appleScriptExecutor: AppleScriptExecutor

    init(appleScriptExecutor: AppleScriptExecutor = AppleScriptExecutor()) {
        self.appleScriptExecutor = appleScriptExecutor
    }

    func fetchPlaylists() async throws -> [String] {
        let script = """
        tell application "Music"
            set playlist_names to {}
            repeat with target_playlist in (get every user playlist)
                set end of playlist_names to name of target_playlist
            end repeat
            return playlist_names
        end tell
        """
        let rawValue = try appleScriptExecutor.run(script: script)
        guard !rawValue.isEmpty else {
            return []
        }
        return rawValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func fetchTracks(in playlistName: String) async throws -> [TrackInfo] {
        let escapedPlaylistName = escapeAppleScriptString(playlistName)
        let script = """
        tell application "Music"
            set output_text to ""
            set target_playlist to user playlist "\(escapedPlaylistName)"
            repeat with target_track in (get every track of target_playlist)
                set track_name to name of target_track
                set track_artist to artist of target_track
                if track_artist is missing value then set track_artist to ""
                set track_album to album of target_track
                if track_album is missing value then set track_album to ""
                set track_duration_value to duration of target_track
                if track_duration_value is missing value then
                    set track_duration to 0
                else
                    set track_duration to track_duration_value as integer
                end if
                set output_text to output_text & track_name & "\\t" & track_artist & "\\t" & track_album & "\\t" & track_duration & "\\n"
            end repeat
            return output_text
        end tell
        """
        let rawValue = try appleScriptExecutor.run(script: script)
        return rawValue
            .split(whereSeparator: \.isNewline)
            .compactMap { lineValue in
                let parts = lineValue.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else {
                    return nil
                }
                return TrackInfo(
                    name: parts[0],
                    artist: parts[1],
                    album: parts[2],
                    durationSeconds: Int(parts[3]) ?? 0,
                    playlistName: playlistName
                )
            }
    }

    func play(track: TrackInfo) async throws {
        let escapedPlaylistName = escapeAppleScriptString(track.playlistName)
        let escapedTrackName = escapeAppleScriptString(track.name)
        let escapedArtistName = escapeAppleScriptString(track.artist)
        let script = """
        tell application "Music"
            set target_playlist to user playlist "\(escapedPlaylistName)"
            set found_tracks to (every track of target_playlist whose name is "\(escapedTrackName)" and artist is "\(escapedArtistName)")
            if (count of found_tracks) > 0 then
                play item 1 of found_tracks
            end if
        end tell
        """
        _ = try appleScriptExecutor.run(script: script)
    }

    func stopPlayback() async {
        _ = try? appleScriptExecutor.run(script: "tell application \"Music\" to stop")
    }

    func pausePlayback() async {
        _ = try? appleScriptExecutor.run(script: "tell application \"Music\" to pause")
    }

    func resumePlayback() async {
        _ = try? appleScriptExecutor.run(script: "tell application \"Music\" to play")
    }

    func setVolume(level: Int) async {
        let clampedLevel = max(0, min(100, level))
        _ = try? appleScriptExecutor.run(script: "tell application \"Music\" to set sound volume to \(clampedLevel)")
    }

    func fetchVolume() async -> Int {
        let rawValue = try? appleScriptExecutor.run(script: "tell application \"Music\" to get sound volume")
        return Int(rawValue ?? "") ?? 0
    }

    func fetchCurrentTrack() async throws -> TrackInfo? {
        let script = """
        tell application "Music"
            if player state is playing or player state is paused then
                set target_track to current track
                set track_artist to artist of target_track
                if track_artist is missing value then set track_artist to ""
                set track_album to album of target_track
                if track_album is missing value then set track_album to ""
                set track_duration_value to duration of target_track
                if track_duration_value is missing value then
                    set track_duration to 0
                else
                    set track_duration to track_duration_value as integer
                end if
                return (name of target_track) & "\\t" & track_artist & "\\t" & track_album & "\\t" & track_duration
            else
                return ""
            end if
        end tell
        """
        let rawValue = try appleScriptExecutor.run(script: script)
        guard !rawValue.isEmpty else {
            return nil
        }
        let parts = rawValue.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else {
            return nil
        }
        return TrackInfo(
            name: parts[0],
            artist: parts[1],
            album: parts[2],
            durationSeconds: Int(parts[3]) ?? 0
        )
    }

    func fetchIsPlaying() async -> Bool {
        let rawValue = try? appleScriptExecutor.run(script: "tell application \"Music\" to get player state")
        return rawValue == "playing"
    }

    func fetchPlaybackPosition() async -> Double {
        let rawValue = try? appleScriptExecutor.run(script: "tell application \"Music\" to get player position")
        return Double(rawValue ?? "") ?? 0
    }

    func seekToPosition(_ seconds: Double) async {
        _ = try? appleScriptExecutor.run(script: "tell application \"Music\" to set player position to \(seconds)")
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Placeholder for future YouTube Music automation support.
struct YouTubeMusicPlaceholderService: MusicService {
    let serviceKind: MusicServiceKind = .youtubeMusic

    func fetchPlaylists() async throws -> [String] {
        throw AppleMusicServiceError.unsupportedService
    }

    func fetchTracks(in playlistName: String) async throws -> [TrackInfo] {
        throw AppleMusicServiceError.unsupportedService
    }

    func play(track: TrackInfo) async throws {
        throw AppleMusicServiceError.unsupportedService
    }

    func stopPlayback() async {}

    func pausePlayback() async {}

    func resumePlayback() async {}

    func setVolume(level: Int) async {}

    func fetchVolume() async -> Int { 0 }

    func fetchCurrentTrack() async throws -> TrackInfo? { nil }

    func fetchIsPlaying() async -> Bool { false }

    func fetchPlaybackPosition() async -> Double { 0 }

    func seekToPosition(_ seconds: Double) async {}
}
