import Foundation

/// Spotify プレイリスト 1 件の DOM 抽出結果。
struct SpotifyPlaylistItem: Codable, Equatable, Sendable {
    let title: String
    let href: String
}

/// Spotify トラック 1 件の DOM 抽出結果。
struct SpotifyTrackItem: Codable, Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let href: String
    let playlistURL: String
    let isPlayable: Bool
    let contentType: String
    let artworkURL: String?

    /// DOM 抽出結果を `TrackInfo` に変換する。
    func toTrackInfo(playlistName: String) -> TrackInfo? {
        guard isPlayable else { return nil }
        guard contentType == "track" else { return nil }
        guard !title.isEmpty else { return nil }
        guard href.contains("/track/") else { return nil }
        return TrackInfo(
            name: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
            playlistName: playlistName,
            serviceID: href,
            artworkURL: artworkURL
        )
    }
}
