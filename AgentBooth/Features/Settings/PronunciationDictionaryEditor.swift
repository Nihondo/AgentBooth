import SwiftUI

/// 発音辞書（`[PronunciationEntry]`）の追加・編集・削除・並べ替え UI。
/// `TTSCredentialSetsEditor` と同じ構造（`.onDrag`/`.onDrop(delegate:)` によるドラッグ並べ替え、
/// 行 + `.popover` の編集フォーム）を踏襲する。
struct PronunciationDictionaryEditor: View {
    @Binding var entries: [PronunciationEntry]
    /// 別スコープ（グローバル⇔プロフィール）で同じ表記が上書きされている場合に警告バッジを出すためのキー集合。
    var overriddenSources: Set<String> = []

    @State private var draggingId: UUID?
    @State private var editingId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entries.isEmpty {
                Text("未登録。追加後に表記と読みを入力。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach($entries) { $entry in
                PronunciationEntryRow(
                    entry: $entry,
                    isEditing: bindingForEditing(entry.id),
                    isOverridden: overriddenSources.contains(PronunciationDictionaryResolver.normalizedSource(entry.source)),
                    onDelete: { deleteEntry(id: entry.id) }
                )
                .onDrag {
                    draggingId = entry.id
                    return NSItemProvider(object: entry.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: PronunciationDropDelegate(
                        targetId: entry.id,
                        entries: $entries,
                        draggingId: $draggingId
                    )
                )
                .opacity(draggingId == entry.id ? 0.4 : 1.0)
            }

            Button("エントリを追加") {
                let newEntry = PronunciationEntry()
                entries.append(newEntry)
                editingId = newEntry.id
            }
            .padding(.top, 4)
        }
    }

    private func bindingForEditing(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { editingId == id },
            set: { isEditing in
                editingId = isEditing ? id : nil
            }
        )
    }

    private func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }

        if editingId == id {
            editingId = nil
        }
    }
}

private struct PronunciationDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var entries: [PronunciationEntry]
    @Binding var draggingId: UUID?

    func dropEntered(info: DropInfo) {
        guard let fromId = draggingId,
              fromId != targetId,
              let fromIdx = entries.firstIndex(where: { $0.id == fromId }),
              let toIdx = entries.firstIndex(where: { $0.id == targetId })
        else { return }
        entries.move(
            fromOffsets: IndexSet(integer: fromIdx),
            toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

private struct PronunciationEntryRow: View {
    @Binding var entry: PronunciationEntry
    @Binding var isEditing: Bool
    let isOverridden: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            Toggle("", isOn: $entry.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            HStack(spacing: 4) {
                Text(entry.source.isEmpty ? String(localized: "表記未設定") : entry.source)
                    .foregroundStyle(entry.source.isEmpty ? .tertiary : .primary)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.reading.isEmpty ? String(localized: "読み未設定") : entry.reading)
                    .foregroundStyle(entry.reading.isEmpty ? .tertiary : .primary)
            }
            .font(.body)
            .lineLimit(1)
            .opacity(entry.isEnabled ? 1.0 : 0.4)

            if isOverridden {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .help("この番組の辞書で上書きされています")
            }

            Spacer()

            Button { isEditing = true } label: { Image(systemName: "pencil") }

            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            PronunciationEntryEditView(entry: $entry)
        }
    }
}

private struct PronunciationEntryEditView: View {
    @Binding var entry: PronunciationEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("発音辞書エントリ編集")
                .font(.headline)

            LabeledContent("表記") {
                TextField("例: 女神転生", text: $entry.source)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            LabeledContent("読み") {
                TextField("例: メガミテンセイ", text: $entry.reading)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            LabeledContent("メモ") {
                TextField("任意", text: $entry.note)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            Toggle("有効", isOn: $entry.isEnabled)

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.return)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}
