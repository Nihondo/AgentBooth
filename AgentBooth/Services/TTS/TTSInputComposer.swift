import Foundation

/// TTS へ渡す単一テキスト入力を組み立てる純関数群。
///
/// `GeminiTTSService` と台本レビュー画面の入力プレビューが同じ関数を共有することで、
/// 「レビュー画面に表示されているもの」と「実際に TTS へ送信されるもの」が常に一致することを保証する。
///
/// 出力順は `Direction:` → `Pronunciation:` → 発話トランスクリプト（`Male:` / `Female:`）。
/// トランスクリプトは常に末尾に置く（モデルは末尾のコンテンツに強く反応するため、既存の挙動を保つ）。
enum TTSInputComposer {
    static func makeInput(
        dialogues: [DialogueLine],
        directionSettings: DirectionSettings,
        pronunciationEntries: [PronunciationEntry] = []
    ) -> String {
        let blocks = [
            makeDirectionBlock(directionSettings: directionSettings),
            makePronunciationBlock(entries: pronunciationEntries, appearingIn: dialogues),
        ].filter { !$0.isEmpty }

        let transcript = makeTranscript(dialogues: dialogues)
        guard !blocks.isEmpty else {
            return transcript
        }
        return (blocks + [transcript]).joined(separator: "\n\n")
    }

    static func makeDirectionBlock(directionSettings: DirectionSettings) -> String {
        let direction = directionSettings.sceneDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !direction.isEmpty else { return "" }
        return """
        Direction:
        \(direction)
        """
    }

    /// 発音辞書ブロックを組み立てる。台詞に実際に出現するエントリのみを列挙し、
    /// 該当するエントリが1つもなければ空文字を返してブロックごと省略する
    /// （辞書未設定時の TTS 入力を既存の出力と完全に一致させるための必須仕様）。
    static func makePronunciationBlock(entries: [PronunciationEntry], appearingIn dialogues: [DialogueLine]) -> String {
        let applicableEntries = entries.filter {
            $0.isEnabled
                && !$0.reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && appliesTo(entry: $0, dialogues: dialogues)
        }
        guard !applicableEntries.isEmpty else { return "" }

        let rules = applicableEntries
            .map { "「\($0.source)」 = 「\($0.reading)」" }
            .joined(separator: "\n")

        return """
        Follow these pronunciation rules exactly.
        These rules affect pronunciation only. Do not alter the transcript.

        Pronunciation dictionary:
        \(rules)
        """
    }

    static func makeTranscript(dialogues: [DialogueLine]) -> String {
        dialogues.map { dialogue in
            let speaker = dialogue.speaker == "male" ? "Male" : "Female"
            return "\(speaker): \(dialogue.text)"
        }.joined(separator: "\n")
    }

    /// 指定エントリの `source` が、いずれかの台詞テキストに実際に出現するか。
    static func appliesTo(entry: PronunciationEntry, dialogues: [DialogueLine]) -> Bool {
        let normalizedSource = PronunciationDictionaryResolver.normalizedSource(entry.source)
        guard !normalizedSource.isEmpty else { return false }
        return dialogues.contains {
            $0.text.precomposedStringWithCanonicalMapping.contains(normalizedSource)
        }
    }
}
