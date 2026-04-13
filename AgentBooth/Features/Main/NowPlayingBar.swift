import SwiftUI

/// 現在再生中のトラック情報をアートワーク付きで表示するバー。
struct NowPlayingBar: View {
    let track: TrackInfo
    let playbackPosition: Double
    let volume: Int
    let trackIndex: Int
    let trackCount: Int

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
                .font(.headline)
                .lineLimit(1)
            Text(track.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !track.album.isEmpty {
                Text(track.album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// 再生位置・音量・トラック番号
    private var playbackInfoView: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(trackIndex + 1)/\(trackCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("\(formatTime(playbackPosition)) / \(formatTime(Double(track.durationSeconds)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Label("\(volume)%", systemImage: "speaker.wave.2.fill")
                .font(.caption)
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
