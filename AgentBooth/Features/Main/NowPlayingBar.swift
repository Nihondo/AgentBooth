import SwiftUI
import AppKit

/// 現在再生中のトラック情報をアートワーク付きで表示するバー。
struct NowPlayingBar: View {
    let track: TrackInfo
    let playbackPosition: Double
    let volume: Int
    let trackIndex: Int
    let trackCount: Int
    let isAppleMusic: Bool

    @State private var fetchedArtwork: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            artworkView
            trackInfoView
            Spacer()
            playbackInfoView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task(id: track.id) {
            guard isAppleMusic, track.artworkURL == nil else { return }
            fetchedArtwork = await AppleMusicArtworkFetcher.fetchArtwork(forTrack: track)
        }
    }

    /// アートワーク画像（60x60）
    private var artworkView: some View {
        Group {
            if let urlString = track.artworkURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        artworkPlaceholder
                    default:
                        ProgressView()
                            .frame(width: 60, height: 60)
                    }
                }
            } else if let artwork = fetchedArtwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// アートワークが取得できない場合のプレースホルダー
    private var artworkPlaceholder: some View {
        ZStack {
            Color(.separatorColor)
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    /// 曲名・アーティスト・アルバム
    private var trackInfoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.name)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(track.artist)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !track.album.isEmpty {
                Text(track.album)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// 再生位置・音量・トラック番号
    private var playbackInfoView: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(trackIndex + 1)/\(trackCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("\(formatTime(playbackPosition)) / \(formatTime(Double(track.durationSeconds)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Label("\(volume)%", systemImage: "speaker.wave.2.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
