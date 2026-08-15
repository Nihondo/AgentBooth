import SwiftUI

/// 全セグメント横断の検索・置換バー。`⌘F` で表示トグル、`Esc` で閉じる（`ScriptReviewView` 側で配線）。
struct ReviewSearchBar: View {
    @ObservedObject var viewModel: ScriptReviewViewModel
    @FocusState var isQueryFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("検索", text: $viewModel.search.query)
                .textFieldStyle(.plain)
                .focused($isQueryFieldFocused)
                .frame(minWidth: 140)
                .onSubmit { viewModel.focusNextMatch() }

            Toggle("Aa", isOn: $viewModel.search.isCaseSensitive)
                .toggleStyle(.button)
                .help("大文字・小文字を区別する")

            Text(matchCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .leading)

            Button {
                viewModel.focusPreviousMatch()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(viewModel.matches.isEmpty)
            .help("前のヒットへ（⇧⌘G）")

            Button {
                viewModel.focusNextMatch()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(viewModel.matches.isEmpty)
            .help("次のヒットへ（⌘G）")

            Divider().frame(height: 16)

            TextField("置換後", text: $viewModel.search.replacement)
                .textFieldStyle(.plain)
                .frame(minWidth: 120)

            Button("置換") {
                viewModel.replaceCurrentMatch()
            }
            .disabled(viewModel.matches.isEmpty)

            Button("すべて置換") {
                viewModel.replaceAllMatches()
            }
            .disabled(viewModel.matches.isEmpty)

            Spacer()

            Button {
                viewModel.search.isBarShown = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("検索バーを閉じる（Esc）")
        }
        .padding(8)
        .background(.bar)
        .onExitCommand {
            viewModel.search.isBarShown = false
        }
        .onAppear {
            isQueryFieldFocused = true
        }
    }

    private var matchCountLabel: String {
        let matches = viewModel.matches
        if viewModel.search.query.isEmpty {
            return ""
        }
        guard !matches.isEmpty else { return String(localized: "0 件") }
        let current = min(max(viewModel.search.currentMatchIndex, 0) + 1, matches.count)
        return "\(current) / \(matches.count)"
    }
}
