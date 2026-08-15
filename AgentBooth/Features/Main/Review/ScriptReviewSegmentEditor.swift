import SwiftUI

/// レビュー画面右ペイン。選択中セグメント1件だけを描画する。
///
/// `List` を使わず `ScrollView { VStack }` で組むのは、同時に生きる `TextEditor` /
/// `TextField` の数を最小限に抑え、キャレット安定性を確保するため（`ScriptReviewViewModel` の
/// ドキュメントコメントを参照）。
struct ScriptReviewSegmentEditor: View {
    @ObservedObject var viewModel: ScriptReviewViewModel
    let segmentID: ReviewSegmentDraft.ID

    @State private var draggingLineID: UUID?
    @State private var isPreviewExpanded = true
    @State private var isRegisteringPronunciation = false
    @State private var pronunciationDraftSource = ""
    @State private var pronunciationDraftReading = ""
    @State private var pronunciationDraftScope: PronunciationScope = .profile
    /// 検索ナビゲーション（次へ/前へ）でフォーカスを移す先。`ReviewMatch.Target` をそのまま使う。
    @FocusState private var focusedTarget: ReviewMatch.Target?

    var body: some View {
        if let segment = viewModel.segment(withID: segmentID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(segment: segment)
                    directionEditor(segment: segment)
                    dialogueEditor(segment: segment)
                    ttsInputPreviewPanel(segment: segment)
                }
                .padding()
            }
            .onChange(of: viewModel.focusRequest) { _, newValue in
                guard let newValue, newValue.segmentID == segment.id else { return }
                focusedTarget = newValue.target
            }
            .alert("この発話を試聴しますか？", isPresented: linePreviewConfirmationBinding) {
                Button("キャンセル", role: .cancel) {
                    viewModel.cancelPendingLinePreviewConfirmation()
                }
                Button("試聴する") {
                    viewModel.confirmLinePreview(skipFutureConfirmations: false)
                }
                Button("試聴する（以後確認しない）") {
                    viewModel.confirmLinePreview(skipFutureConfirmations: true)
                }
            } message: {
                Text("Gemini TTS API を1回消費します。")
            }
        } else {
            ContentUnavailableView(
                "セグメントが見つかりません",
                systemImage: "questionmark.circle"
            )
        }
    }

    // MARK: - Header

    private func header(segment: ReviewSegmentDraft) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(segment.segmentLabel)
                    .font(.title3)
                    .fontWeight(.semibold)

                HStack(spacing: 16) {
                    Label(segment.maleVoiceName.isEmpty ? String(localized: "未設定") : segment.maleVoiceName, systemImage: "person.fill")
                    Label(segment.femaleVoiceName.isEmpty ? String(localized: "未設定") : segment.femaleVoiceName, systemImage: "person.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.undoLastStructuralChange()
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .keyboardShortcut("z", modifiers: [.command, .option])
        }
    }

    // MARK: - 発話指示

    private func directionEditor(segment: ReviewSegmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("発話指示")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DraftTextEditor(
                seed: segment.sceneDirection,
                seedToken: viewModel.seedToken(for: segment.id),
                style: .multiline(minHeight: 40, maxHeight: 120),
                focusBinding: $focusedTarget,
                focusValue: .sceneDirection,
                onCommitText: { newValue in
                    viewModel.updateSceneDirection(segmentID: segment.id, text: newValue)
                }
            )
        }
    }

    // MARK: - 発話

    private func dialogueEditor(segment: ReviewSegmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: String(localized: "発話（%d 行）"), segment.lines.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let nextSpeaker = segment.lines.last?.speaker.toggled ?? .male
                    viewModel.appendLine(to: segment.id, speaker: nextSpeaker)
                } label: {
                    Label("行を追加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            VStack(spacing: 0) {
                ForEach(Array(segment.lines.enumerated()), id: \.element.id) { index, line in
                    DialogueLineRow(
                        line: line,
                        seedToken: viewModel.seedToken(for: line.id),
                        canDelete: segment.lines.count > 1,
                        previewState: viewModel.linePreviewStates[line.id] ?? .idle,
                        canPreview: canPreview(line: line),
                        previewHelpText: previewHelpText(line: line),
                        onCommitText: { newValue in
                            viewModel.updateLineText(segmentID: segment.id, lineID: line.id, text: newValue)
                        },
                        onSelectSpeaker: { speaker in
                            viewModel.setSpeaker(speaker, of: line.id, in: segment.id)
                        },
                        onPreview: {
                            viewModel.requestLinePreview(line.id, in: segment.id)
                        },
                        onStopPreview: {
                            viewModel.stopSegmentPreview()
                        },
                        onDelete: {
                            viewModel.removeLine(line.id, in: segment.id)
                        },
                        focusBinding: $focusedTarget
                    )
                    .padding(.vertical, 5)
                    .opacity(draggingLineID == line.id ? 0.4 : 1.0)
                    .onDrag {
                        draggingLineID = line.id
                        viewModel.beginLineDragReorder()
                        return NSItemProvider(object: line.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: DialogueLineDropDelegate(
                            targetLineID: line.id,
                            segmentID: segment.id,
                            viewModel: viewModel,
                            draggingLineID: $draggingLineID
                        )
                    )

                    if index < segment.lines.count - 1 {
                        InsertLineHoverDivider {
                            viewModel.insertLine(in: segment.id, after: line.id, speaker: line.speaker.toggled)
                        }
                    }
                }
            }
        }
    }

    private var linePreviewConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingLinePreviewConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelPendingLinePreviewConfirmation()
                }
            }
        )
    }

    private func canPreview(line: ReviewLineDraft) -> Bool {
        viewModel.canPreviewSegments
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func previewHelpText(line: ReviewLineDraft) -> String {
        if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "発話テキストを入力してください")
        }
        if !viewModel.canPreviewSegments {
            return String(localized: "有効な TTS 資格情報がありません")
        }
        return String(localized: "この発話だけを試聴します（TTS API を1回消費します）")
    }

    // MARK: - TTS 入力プレビュー / 発音辞書クイック登録

    private func ttsInputPreviewPanel(segment: ReviewSegmentDraft) -> some View {
        DisclosureGroup(isExpanded: $isPreviewExpanded) {
            ScrollView {
                Text(viewModel.ttsInputPreview(for: segment.id))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } label: {
            HStack {
                Text("TTS へ渡る入力")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                previewButton(segment: segment)
                Button {
                    pronunciationDraftSource = ""
                    pronunciationDraftReading = ""
                    pronunciationDraftScope = .profile
                    isRegisteringPronunciation = true
                } label: {
                    Label("辞書に登録", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isRegisteringPronunciation, arrowEdge: .top) {
                    PronunciationQuickRegisterView(
                        source: $pronunciationDraftSource,
                        reading: $pronunciationDraftReading,
                        scope: $pronunciationDraftScope,
                        doesNotAppearInSegment: !TTSInputComposer.appliesTo(
                            entry: PronunciationEntry(source: pronunciationDraftSource, reading: pronunciationDraftReading),
                            dialogues: segment.dialogueLines
                        ),
                        onRegister: {
                            try? viewModel.registerPronunciation(
                                source: pronunciationDraftSource,
                                reading: pronunciationDraftReading,
                                scope: pronunciationDraftScope
                            )
                            isRegisteringPronunciation = false
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func previewButton(segment: ReviewSegmentDraft) -> some View {
        let state = viewModel.previewStates[segment.id] ?? .idle
        switch state {
        case .synthesizing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("合成中…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .playing:
            Button {
                viewModel.stopSegmentPreview()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.borderless)

        default:
            Button {
                viewModel.requestSegmentPreview(segment.id)
            } label: {
                Label("試聴", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canPreviewSegments)
            .help(viewModel.canPreviewSegments ? "このセグメントを試聴します（TTS API を1回消費します）" : "有効な TTS 資格情報がありません")
            .alert(
                "このセグメントを試聴しますか？",
                isPresented: Binding(
                    get: { viewModel.pendingPreviewConfirmationSegmentID == segment.id },
                    set: { isPresented in
                        if !isPresented { viewModel.cancelPendingPreviewConfirmation() }
                    }
                )
            ) {
                Button("キャンセル", role: .cancel) {
                    viewModel.cancelPendingPreviewConfirmation()
                }
                Button("試聴する") {
                    viewModel.confirmSegmentPreview(segment.id, skipFutureConfirmations: false)
                }
                Button("試聴する（以後確認しない）") {
                    viewModel.confirmSegmentPreview(segment.id, skipFutureConfirmations: true)
                }
            } message: {
                Text("Gemini TTS API を1回消費します。")
            }

            if case .failed(let message) = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            }
        }
    }
}

/// ドラッグ中の発話行を、ドロップ先の行の位置へ並べ替えるための `DropDelegate`。
/// undo スナップショットはドラッグ開始時（`.onDrag`）で1回だけ積むため、
/// `dropEntered` が連続で呼ばれても undo スタックは積み増さない。
private struct DialogueLineDropDelegate: DropDelegate {
    let targetLineID: UUID
    let segmentID: UUID
    let viewModel: ScriptReviewViewModel
    @Binding var draggingLineID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingLineID, draggingLineID != targetLineID,
              let segment = viewModel.segment(withID: segmentID),
              let toIndex = segment.lines.firstIndex(where: { $0.id == targetLineID }) else { return }
        viewModel.reorderLineDuringDrag(draggingLineID, in: segmentID, to: toIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingLineID = nil
        return true
    }
}

/// 発音辞書へのクイック登録フォーム。「表記」「読み」「保存先」を入力し、辞書へ即時反映する。
private struct PronunciationQuickRegisterView: View {
    @Binding var source: String
    @Binding var reading: String
    @Binding var scope: PronunciationScope
    let doesNotAppearInSegment: Bool
    let onRegister: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var canRegister: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("発音辞書に登録")
                .font(.headline)

            LabeledContent("表記") {
                TextField("例: 女神転生", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            LabeledContent("読み") {
                TextField("例: メガミテンセイ", text: $reading)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            Picker("保存先", selection: $scope) {
                ForEach(PronunciationScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.radioGroup)

            if !source.isEmpty, doesNotAppearInSegment {
                Label("この語はこのセグメントに出現しません", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("登録") {
                    onRegister()
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!canRegister)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

/// 行と行の間にカーソルを乗せたときだけ「＋」ボタンを表示し、その位置に新しい行を挿入できるようにする薄い区切り。
private struct InsertLineHoverDivider: View {
    let onInsert: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Divider()
            if isHovering {
                Button(action: onInsert) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .help("この位置に行を挿入")
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
