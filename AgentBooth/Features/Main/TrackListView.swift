import SwiftUI

/// プレイリストのトラック一覧を表示するテーブルビュー。
struct TrackListView: View {
    let tracks: [TrackInfo]
    let currentPlayingTrackID: String?
    let trackListState: TrackListState
    let isRadioRunning: Bool
    let currentPlaybackPosition: Double

    var body: some View {
        Group {
            switch trackListState {
            case .idle:
                emptyState(message: "プレイリストを選択してください")
            case .loading:
                loadingState
            case .failed(let message):
                emptyState(message: message)
            case .loaded:
                trackTable
            }
        }
    }

    /// ラジオ実行中は radioState 側のデータを使うため、状態に関わらずテーブルを表示
    @ViewBuilder
    private var trackTable: some View {
        if tracks.isEmpty {
            emptyState(message: "トラックがありません")
        } else {
            Table(tracks) {
                TableColumn("#") { track in
                    let index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
                    Text("\(index + 1)")
                        .monospacedDigit()
                        .foregroundStyle(isCurrentTrack(track) ? .primary : .secondary)
                }
                .width(min: 30, ideal: 36, max: 44)

                TableColumn("曲名") { track in
                    HStack(spacing: 6) {
                        if isCurrentTrack(track) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        Text(track.name)
                            .lineLimit(1)
                            .fontWeight(isCurrentTrack(track) ? .semibold : .regular)
                    }
                }
                .width(min: 140, ideal: 220)

                TableColumn("アーティスト") { track in
                    Text(track.artist)
                        .lineLimit(1)
                        .foregroundStyle(isCurrentTrack(track) ? .primary : .secondary)
                }
                .width(min: 100, ideal: 160)

                TableColumn("アルバム") { track in
                    Text(track.album)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 160)

                TableColumn("時間") { track in
                    Text(formatDuration(track.durationSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 44, ideal: 54, max: 64)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func isCurrentTrack(_ track: TrackInfo) -> Bool {
        guard let currentID = currentPlayingTrackID else { return false }
        return track.id == currentID
    }

    private func emptyState(message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView("トラック一覧を取得中...")
                .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
