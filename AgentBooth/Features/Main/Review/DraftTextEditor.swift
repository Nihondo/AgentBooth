import SwiftUI

/// キャレット位置を保護するテキスト入力。
///
/// `ScriptReviewViewModel.segments` は意図的に `@Published` ではないため、打鍵の都度
/// 外部（ViewModel）から新しい文字列が降ってくることはない。しかし行の追加・削除・並べ替え・
/// 置換・undo が起きたときは、対応するエディタの内容を強制的に差し替える必要がある。
///
/// `seed` / `seedToken` は「外部から書き込むための種」であり、通常の打鍵では読まれない。
/// `seedToken`（対象の安定 ID + `structureRevision`）が変化したときにだけ `text` を `seed` で
/// 上書きする。打鍵ごとに `onCommitText` を呼ぶが、これは ViewModel の非 publish な書き込みメソッドに
/// つながるため `objectWillChange` は発火せず、この View 自身も再構築されない。
struct DraftTextEditor: View {
    enum Style {
        /// 複数行の自由入力（発話指示など）。高さの範囲を固定して `TextEditor` で描画する。
        case multiline(minHeight: CGFloat, maxHeight: CGFloat)
        /// 内容に応じて伸び縮みする1項目の入力（発話テキストなど）。
        case growingField(lineLimit: ClosedRange<Int>)
    }

    let seed: String
    let seedToken: ReviewSeedToken
    let style: Style
    let placeholder: String
    let onCommitText: (String) -> Void
    /// 検索ナビゲーション（次へ/前へ）が「このエディタへフォーカスを移す」ために使う外部束縛。
    /// 親（`ScriptReviewSegmentEditor`）が単一の `@FocusState var focusedTarget: ReviewMatch.Target?` を
    /// 所有し、各エディタへ自分の `focusValue` とともに渡すことで、`ReviewMatch` のヒットへジャンプできる。
    let focusBinding: FocusState<ReviewMatch.Target?>.Binding
    let focusValue: ReviewMatch.Target

    @State private var text: String

    init(
        seed: String,
        seedToken: ReviewSeedToken,
        style: Style = .growingField(lineLimit: 1...10),
        placeholder: String = "",
        focusBinding: FocusState<ReviewMatch.Target?>.Binding,
        focusValue: ReviewMatch.Target,
        onCommitText: @escaping (String) -> Void
    ) {
        self.seed = seed
        self.seedToken = seedToken
        self.style = style
        self.placeholder = placeholder
        self.focusBinding = focusBinding
        self.focusValue = focusValue
        self.onCommitText = onCommitText
        _text = State(initialValue: seed)
    }

    var body: some View {
        Group {
            switch style {
            case .multiline(let minHeight, let maxHeight):
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: minHeight, maxHeight: maxHeight)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && !placeholder.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }

            case .growingField(let lineLimit):
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(lineLimit)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .focused(focusBinding, equals: focusValue)
        .onChange(of: text) { _, newValue in
            onCommitText(newValue)
        }
        .onChange(of: seedToken) { _, _ in
            text = seed
        }
    }
}
