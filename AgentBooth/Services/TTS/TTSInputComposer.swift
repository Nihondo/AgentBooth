import Foundation

/// `GeminiTTSRequestSchema.speechMetadata` 送信用に構造化された1発話ターン。
/// `speaker` は単一話者入力では nil（`GeminiTTSService` 側の `speechConfig` が声を確定するため、
/// 読み上げに影響し得るラベルを本文へ書かない）。
struct TTSTurn: Equatable, Sendable {
    let speaker: String?
    let text: String
}

/// `GeminiTTSRequestSchema.speechMetadata` 送信用の構造化 TTS 入力。
/// `style` は全ターン共通の演技指示（`sceneDirection`）で、空なら nil。
struct StructuredTTSInput: Equatable, Sendable {
    let style: String?
    let turns: [TTSTurn]
}

/// TTS へ渡す入力を組み立てる純関数群。
///
/// `GeminiTTSService` と台本レビュー画面の入力プレビューが同じ関数を共有することで、
/// 「レビュー画面に表示されているもの」と「実際に TTS へ送信されるもの」が常に一致することを保証する。
///
/// Gemini 2.5 / 3.1 系（`GeminiTTSRequestSchema.legacyPrompt`）は単一テキストのプロンプトを使う。
/// 指示モードの出力順は `Direction:` → `Pronunciation:` → 発話トランスクリプト（`Male:` / `Female:`）。
/// 置換モードでは `Pronunciation:` を省略し、トランスクリプト内の該当表記だけを読みへ置換する。
/// トランスクリプトは常に末尾に置く（モデルは末尾のコンテンツに強く反応するため、既存の挙動を保つ）。
///
/// Gemini 3.8 以降（`GeminiTTSRequestSchema.speechMetadata`）は入力テキストを逐語トランスクリプトとして
/// 扱うため、`Direction:` ブロックや `Male:` ラベルのような地の文を本文へ書き込むと読み上げられてしまう。
/// この経路では `makeStructuredInput` を使い、演技指示は `style`、話者は `speaker` として
/// part ごとのメタデータへ分離する。発音辞書は「発音指示として追加」モードでも、ルール文自体が
/// 読まれるのを避けるため常にトランスクリプト置換（`.replaceTranscript` 相当）を適用する。
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
            // legacy プロンプトを送るモデル（2.5 / 3.1）は `<laugh>` のようなインラインタグを
            // 演技指示として解釈しないため、そのまま送ると文字どおり読み上げられる。
            let strippedText = stripInlineVocalTags(text)
            guard !isSingleSpeaker else { return strippedText }
            let speaker = dialogue.speaker == "male" ? "Male" : "Female"
            return "\(speaker): \(strippedText)"
        }.joined(separator: "\n")
    }

    /// `GeminiTTSRequestSchema.speechMetadata`（Gemini 3.8 以降）向けの構造化入力を組み立てる。
    /// 演技指示は全ターン共通の `style` へ、話者は `speaker` へ分離し、本文には
    /// 逐語トランスクリプトのみを残す（legacy 経路のような `Direction:` / `Male:` ラベルは書かない）。
    /// 発音辞書はモード指定に関わらず常にトランスクリプト置換を適用する
    /// （ルール文をそのまま本文に書くと読み上げられてしまうため）。
    /// インラインの発話タグ（`<laugh>` 等）は 3.8 側でサポートされるため、除去せずそのまま残す。
    static func makeStructuredInput(
        dialogues: [DialogueLine],
        directionSettings: DirectionSettings,
        pronunciationEntries: [PronunciationEntry] = []
    ) -> StructuredTTSInput {
        let style = directionSettings.sceneDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSingleSpeaker = speakerLabels(in: dialogues).count <= 1
        let turns = dialogues.map { dialogue -> TTSTurn in
            let text = replacePronunciations(in: dialogue.text, entries: pronunciationEntries)
            let speaker = isSingleSpeaker ? nil : (dialogue.speaker == "male" ? "Male" : "Female")
            return TTSTurn(speaker: speaker, text: text)
        }
        return StructuredTTSInput(style: style.isEmpty ? nil : style, turns: turns)
    }

    /// 台本レビュー画面のプレビュー表示、および音声キャッシュのフィンガープリント用に、
    /// 実際に TTS へ送信される内容を人間可読な文字列として返す。
    /// `.speechMetadata` 側の戻り値は表示専用の決定的な文字列であり、実際のワイヤーフォーマット
    /// （part ごとの JSON）そのものではないことに注意。
    static func makePreviewText(
        dialogues: [DialogueLine],
        directionSettings: DirectionSettings,
        pronunciationEntries: [PronunciationEntry] = [],
        schema: GeminiTTSRequestSchema
    ) -> String {
        switch schema {
        case .legacyPrompt:
            return makeInput(
                dialogues: dialogues,
                directionSettings: directionSettings,
                pronunciationEntries: pronunciationEntries
            )
        case .speechMetadata:
            let structured = makeStructuredInput(
                dialogues: dialogues,
                directionSettings: directionSettings,
                pronunciationEntries: pronunciationEntries
            )
            var lines: [String] = []
            if let style = structured.style {
                lines.append("Style: \(style)")
                lines.append("")
            }
            lines.append(contentsOf: structured.turns.map { turn in
                guard let speaker = turn.speaker else { return turn.text }
                return "[\(speaker)] \(turn.text)"
            })
            return lines.joined(separator: "\n")
        }
    }

    /// 発話中の間や非言語音を表す、ホワイトリストに載ったインラインタグだけを取り除く。
    /// `<laugh>` `<sigh>` `<cough>` `<breath>` `<short pause>` `<long pause>` 以外の
    /// 山括弧表記（通常の文章に含まれ得る `<` や独自タグ）には触れない。
    /// タグが1つも含まれない入力に対しては出力がバイト単位で不変であることを保証する。
    static func stripInlineVocalTags(_ text: String) -> String {
        let pattern = "\\s*<(?:laugh|sigh|cough|breath|short pause|long pause)>\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else {
            return text
        }
        let replaced = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return replaced.trimmingCharacters(in: .whitespaces)
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
