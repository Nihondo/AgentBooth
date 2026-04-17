import SwiftUI

struct TTSCredentialSetsEditor: View {
    @Binding var credentialSets: [TTSCredentialSet]
    @State private var draggingId: UUID?
    @State private var editingId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if credentialSets.isEmpty {
                Text("セット未登録。追加後に API Key とモデル名を入力。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach($credentialSets) { $set in
                TTSCredentialSetRow(
                    set: $set,
                    isEditing: bindingForEditing(set.id),
                    onDelete: { deleteSet(id: set.id) }
                )
                .onDrag {
                    draggingId = set.id
                    return NSItemProvider(object: set.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: TTSDropDelegate(
                        targetId: set.id,
                        credentialSets: $credentialSets,
                        draggingId: $draggingId
                    )
                )
                .opacity(draggingId == set.id ? 0.4 : 1.0)
            }

            Button("セットを追加") {
                let newSet = TTSCredentialSet()
                credentialSets.append(newSet)
                editingId = newSet.id
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

    private func deleteSet(id: UUID) {
        credentialSets.removeAll { $0.id == id }

        if editingId == id {
            editingId = nil
        }
    }
}

private struct TTSDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var credentialSets: [TTSCredentialSet]
    @Binding var draggingId: UUID?

    func dropEntered(info: DropInfo) {
        guard let fromId = draggingId,
              fromId != targetId,
              let fromIdx = credentialSets.firstIndex(where: { $0.id == fromId }),
              let toIdx = credentialSets.firstIndex(where: { $0.id == targetId })
        else { return }
        credentialSets.move(
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

private struct TTSCredentialSetRow: View {
    @Binding var set: TTSCredentialSet
    @Binding var isEditing: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            Text(set.label.isEmpty ? "未設定" : set.label)
                .font(.body)
                .foregroundStyle(set.label.isEmpty ? .tertiary : .primary)
                .lineLimit(1)

            Spacer()

            Button { isEditing = true } label: { Image(systemName: "pencil") }

            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            TTSCredentialSetEditView(set: $set)
        }
    }
}

private struct TTSCredentialSetEditView: View {
    @Binding var set: TTSCredentialSet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TTS セット編集")
                .font(.headline)

            LabeledContent("名前") {
                TextField("任意", text: $set.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            LabeledContent("API Key") {
                SecureField("Gemini API Key", text: $set.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            LabeledContent("モデル名") {
                TextField("gemini-2.5-flash-preview-tts", text: $set.modelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

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
