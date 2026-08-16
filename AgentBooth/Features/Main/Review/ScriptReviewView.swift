import SwiftUI

/// 事前生成モードで全セグメントの台本と TTS 入力をレビュー・編集する独立ウィンドウ。
///
/// `ContentView` への `.sheet` ではなく `Window(id: WindowIdentifier.scriptReview)` として
/// 開かれるため、自由にリサイズ・最大化できる。ウィンドウを閉じても編集内容と番組の中断状態は
/// 保持され（`MainViewModel.reviewViewModel` が所有）、メイン画面から再度開いて続きを編集できる。
struct ScriptReviewView: View {
    @ObservedObject var viewModel: ScriptReviewViewModel
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.search.isBarShown {
                ReviewSearchBar(viewModel: viewModel)
                Divider()
            }

            NavigationSplitView {
                segmentSidebar
            } detail: {
                if let selectedID = viewModel.selectedSegmentID {
                    ScriptReviewSegmentEditor(viewModel: viewModel, segmentID: selectedID)
                } else {
                    ContentUnavailableView(
                        "セグメントを選択してください",
                        systemImage: "text.bubble"
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)

            // `.safeAreaInset` ではなく通常の VStack の一部として配置する。
            // NavigationSplitView に safeAreaInset を付けると、detail 側にネストした
            // ScriptReviewSegmentEditor 内部の ScrollView（TTS 入力プレビュー）まで
            // 安全領域が正しく伝播せず、このアクションバーの下に隠れてしまうため。
            actionBar
        }
        .frame(minWidth: 900, minHeight: 640)
        .background {
            // ⌘F / ⌘G / ⇧⌘G はウィンドウ全体で常時有効な非表示ボタンとして配線する
            // （検索バーが閉じていても ⌘F で開けるようにするため）。
            Group {
                Button("") { viewModel.search.isBarShown = true }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("") { viewModel.focusNextMatch() }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("") { viewModel.focusPreviousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    // MARK: - Sidebar

    private var segmentSidebar: some View {
        List(selection: $viewModel.selectedSegmentID) {
            Section {
                ForEach(viewModel.segments) { segment in
                    segmentRow(segment: segment)
                        .tag(segment.id)
                }
            } header: {
                Text(String(format: String(localized: "セグメント（%d）"), viewModel.segments.count))
            }
        }
        .navigationTitle("台本レビュー")
    }

    private func segmentRow(segment: ReviewSegmentDraft) -> some View {
        HStack {
            Text(segment.segmentLabel)
            Spacer()
            if !viewModel.search.query.isEmpty {
                let hitCount = viewModel.matchCount(for: segment.id)
                if hitCount > 0 {
                    Text("\(hitCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            if segmentHasValidationIssue(segment) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("空の発話行があります")
            }
        }
    }

    private func segmentHasValidationIssue(_ segment: ReviewSegmentDraft) -> Bool {
        viewModel.validationIssues.contains {
            switch $0 {
            case .emptyLine(let segmentID, _), .emptySegment(let segmentID):
                return segmentID == segment.id
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("キャンセル（番組を停止）", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !viewModel.validationIssues.isEmpty {
                    Label(
                        String(format: String(localized: "警告: %d 件"), viewModel.validationIssues.count),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Toggle("終了後も保持", isOn: $viewModel.preservesShowCacheAfterCompletion)
                    .help("番組を最後まで再生し終えても台本と音声キャッシュを保持します。次回同じプレイリストで再開すると、変更していないセグメントの音声を再利用できます。")

                Button("承認して再生") {
                    onApprove()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .background(.bar)
    }
}
