import AppKit

/// Apple Music のアートワークを AppleScript 経由で取得するユーティリティ。
enum AppleMusicArtworkFetcher {
    /// 指定トラックのアートワーク画像を返す。再生中でなくても取得可。取得不可の場合は nil。
    static func fetchArtwork(forTrack track: TrackInfo) async -> NSImage? {
        let playlist = escapeAS(track.playlistName)
        let name = escapeAS(track.name)
        let artist = escapeAS(track.artist)
        let source = """
        tell application "Music"
            set candidates to (every track of user playlist "\(playlist)" whose name is "\(name)" and artist is "\(artist)")
            if (count of candidates) is 0 then return "NO_TRACK"
            set t to item 1 of candidates
            if (count of artworks of t) is 0 then return "NO_ARTWORK"
            return (data of artwork 1 of t)
        end tell
        """
        return await runScript(source)
    }

    private static func escapeAS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runScript(_ source: String) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                var errorDict: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorDict)
                guard errorDict == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                if let text = descriptor.stringValue, text == "NO_TRACK" || text == "NO_ARTWORK" {
                    continuation.resume(returning: nil)
                    return
                }
                let data = descriptor.data
                continuation.resume(returning: data.isEmpty ? nil : NSImage(data: data))
            }
        }
    }
}
