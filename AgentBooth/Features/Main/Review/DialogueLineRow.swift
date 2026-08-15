import SwiftUI

/// 発話1行分の行 View。ドラッグハンドル・話者切替・発話テキスト・並べ替え/削除ボタンを横並びに表示する。
///
/// ドラッグ&ドロップ（`.onDrag` / `.onDrop`）は行の識別だけでなく並べ替え先の判定に周辺の行情報が
/// 必要なため、この View 自体には付与せず、呼び出し元（`ScriptReviewSegmentEditor`）が付与する。
struct DialogueLineRow: View {
    let segmentID: UUID
    let line: ReviewLineDraft
    let seedToken: ReviewSeedToken
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canDelete: Bool
    let onCommitText: (String) -> Void
    let onSelectSpeaker: (ReviewSpeaker) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
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

            VStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .help("上へ移動")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .help("下へ移動")
            }
            .buttonStyle(.borderless)
            .font(.caption)
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

    private func speakerColor(_ speaker: ReviewSpeaker) -> Color {
        switch speaker {
        case .male: return .blue
        case .female: return .pink
        }
    }
}
