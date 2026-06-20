import SwiftUI

/// 事前生成モードで全セグメントの台本と TTS 入力をレビュー・編集する画面。
struct ScriptReviewView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            scrollableContent
            Divider()
            actionBar
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("台本レビュー")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text("\(viewModel.reviewItems.count) セグメント")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Content

    private var scrollableContent: some View {
        List {
            ForEach($viewModel.reviewItems) { $item in
                segmentSection(item: $item)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func segmentSection(item: Binding<ReviewScriptItem>) -> some View {
        Section {
            // 発話指示
            directionEditor(item: item)

            // 音声
            voiceInfo(item: item.wrappedValue)

            // 会話
            dialogueList(item: item)
        } header: {
            Text(item.wrappedValue.segmentLabel)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func directionEditor(item: Binding<ReviewScriptItem>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("発話指示")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: item.sceneDirection)
                .font(.body)
                .frame(minHeight: 40, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 2)
    }

    private func voiceInfo(item: ReviewScriptItem) -> some View {
        HStack(spacing: 16) {
            Label(item.maleVoiceName.isEmpty ? "未設定" : item.maleVoiceName, systemImage: "person.fill")
                .foregroundStyle(.secondary)
            Label(item.femaleVoiceName.isEmpty ? "未設定" : item.femaleVoiceName, systemImage: "person.fill")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func dialogueList(item: Binding<ReviewScriptItem>) -> some View {
        ForEach(item.script.dialogues.indices, id: \.self) { index in
            dialogueRow(dialogue: item.script.dialogues[index])
        }
    }

    @ViewBuilder
    private func dialogueRow(dialogue: Binding<DialogueLine>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(speakerDisplayName(dialogue.wrappedValue.speaker))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(speakerColor(dialogue.wrappedValue.speaker))
                .frame(width: 50, alignment: .trailing)
                .padding(.top, 4)

            TextField("発話テキスト", text: dialogue.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 1)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button("キャンセル", role: .cancel) {
                viewModel.cancelScriptReview()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("承認して再生") {
                viewModel.approveScriptReview()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Helpers

    private func speakerDisplayName(_ speaker: String) -> String {
        switch speaker {
        case "male": return "男性"
        case "female": return "女性"
        default: return speaker
        }
    }

    private func speakerColor(_ speaker: String) -> Color {
        switch speaker {
        case "male": return .blue
        case "female": return .pink
        default: return .primary
        }
    }
}
