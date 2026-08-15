import SwiftUI

/// 発話1行分の行 View。ドラッグハンドル・話者切替・発話テキスト・試聴/削除ボタンを横並びに表示する。
///
/// ドラッグ&ドロップ（`.onDrag` / `.onDrop`）は行の識別だけでなく並べ替え先の判定に周辺の行情報が
/// 必要なため、この View 自体には付与せず、呼び出し元（`ScriptReviewSegmentEditor`）が付与する。
struct DialogueLineRow: View {
    let line: ReviewLineDraft
    let seedToken: ReviewSeedToken
    let canDelete: Bool
    let previewState: SegmentPreviewState
    let canPreview: Bool
    let previewHelpText: String
    let onCommitText: (String) -> Void
    let onSelectSpeaker: (ReviewSpeaker) -> Void
    let onPreview: () -> Void
    let onStopPreview: () -> Void
    let onDelete: () -> Void
    let focusBinding: FocusState<ReviewMatch.Target?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .padding(.top, 6)
                .help("ドラッグして並べ替え")

            Picker("", selection: Binding(get: { line.speaker }, set: onSelectSpeaker)) {
                ForEach(ReviewSpeaker.allCases) { speaker in
                    Text(speaker.displayName).tag(speaker)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 78)
            .tint(speakerColor(line.speaker))

            DraftTextEditor(
                seed: line.text,
                seedToken: seedToken,
                style: .growingField(lineLimit: 1...10),
                placeholder: String(localized: "発話テキスト"),
                focusBinding: focusBinding,
                focusValue: .line(line.id),
                onCommitText: onCommitText
            )

            previewControl
                .padding(.top, 4)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "この行を削除" : "セグメントの最後の1行は削除できません")
            .padding(.top, 4)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var previewControl: some View {
        switch previewState {
        case .synthesizing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
                .help("この発話を合成しています")

        case .playing:
            Button(action: onStopPreview) {
                Image(systemName: "stop.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("発話確認を停止")

        default:
            HStack(spacing: 2) {
                Button(action: onPreview) {
                    Image(systemName: "play.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canPreview)
                .help(previewHelpText)

                if case .failed(let message) = previewState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(message)
                }
            }
        }
    }

    private func speakerColor(_ speaker: ReviewSpeaker) -> Color {
        switch speaker {
        case .male: return .blue
        case .female: return .pink
        }
    }
}
