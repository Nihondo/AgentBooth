import Foundation

/// TTS へ渡す単一テキスト入力を組み立てる純関数群。
///
/// `GeminiTTSService` と台本レビュー画面の入力プレビューが同じ関数を共有することで、
/// 「レビュー画面に表示されているもの」と「実際に TTS へ送信されるもの」が常に一致することを保証する。
///
/// 指示モードの出力順は `Direction:` → `Pronunciation:` → 発話トランスクリプト（`Male:` / `Female:`）。
/// 置換モードでは `Pronunciation:` を省略し、トランスクリプト内の該当表記だけを読みへ置換する。
/// トランスクリプトは常に末尾に置く（モデルは末尾のコンテンツに強く反応するため、既存の挙動を保つ）。
enum TTSInputComposer {
    static func makeInput(
        dialogues: [DialogueLine],
        directionSettings: DirectionSettings,
        pronunciationEntries: [PronunciationEntry] = []
    ) -> String {
        var blocks = [makeDirectionBlock(directionSettings: directionSettings)]
        if directionSettings.pronunciationApplicationMode == .instruction {
            blocks.append(makePronunciationBlock(entries: pronunciationEntries, appearingIn: dialogues))
        }
        blocks = blocks.filter { !$0.isEmpty }

        let transcript = makeTranscript(
            dialogues: dialogues,
            pronunciationEntries: pronunciationEntries,
            applicationMode: directionSettings.pronunciationApplicationMode
        )
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

    static func makeTranscript(
        dialogues: [DialogueLine],
        pronunciationEntries: [PronunciationEntry] = [],
        applicationMode: PronunciationApplicationMode = .instruction
    ) -> String {
        // 単一話者の入力では speechConfig 側（単一話者 voiceConfig）で声が確定するため、
        // 話者ラベルは付けない。付けたままだとラベル自体が読み上げられる恐れがある。
        let isSingleSpeaker = speakerLabels(in: dialogues).count <= 1
        return dialogues.map { dialogue in
            let text = applicationMode == .replaceTranscript
                ? replacePronunciations(in: dialogue.text, entries: pronunciationEntries)
                : dialogue.text
            guard !isSingleSpeaker else { return text }
            let speaker = dialogue.speaker == "male" ? "Male" : "Female"
            return "\(speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// 台詞に登場する話者ラベルを登場順・重複なしで返す（"Male" / "Female"）。
    /// 単一話者かどうかの判定と、`GeminiTTSService` の speechConfig 構築の両方がこの1箇所を参照する。
    static func speakerLabels(in dialogues: [DialogueLine]) -> [String] {
        var seen: Set<String> = []
        var labels: [String] = []
        for dialogue in dialogues {
            let label = dialogue.speaker == "male" ? "Male" : "Female"
            guard !seen.contains(label) else { continue }
            seen.insert(label)
            labels.append(label)
        }
        return labels
    }

    /// 原文を左から1回だけ走査し、同じ位置で複数の表記が一致する場合は最長の表記を採用する。
    /// 挿入した読みは再走査しないため、辞書エントリ同士による連鎖置換は発生しない。
    static func replacePronunciations(in text: String, entries: [PronunciationEntry]) -> String {
        let rules = replacementRules(from: entries)
        guard !rules.isEmpty else { return text }

        let normalizedText = text.precomposedStringWithCanonicalMapping
        var result = ""
        var cursor = normalizedText.startIndex

        while cursor < normalizedText.endIndex {
            let suffix = normalizedText[cursor...]
            if let rule = rules.first(where: { suffix.hasPrefix($0.source) }) {
                result.append(rule.reading)
                cursor = normalizedText.index(cursor, offsetBy: rule.source.count)
            } else {
                let nextIndex = normalizedText.index(after: cursor)
                result.append(contentsOf: normalizedText[cursor..<nextIndex])
                cursor = nextIndex
            }
        }
        return result
    }

    private static func replacementRules(from entries: [PronunciationEntry]) -> [(source: String, reading: String)] {
        PronunciationDictionaryResolver.merge(global: entries, profile: [])
            .map {
                (
                    source: PronunciationDictionaryResolver.normalizedSource($0.source),
                    reading: $0.reading.trimmingCharacters(in: .whitespacesAndNewlines)
                        .precomposedStringWithCanonicalMapping
                )
            }
            .sorted { lhs, rhs in
                lhs.source.count > rhs.source.count
            }
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
