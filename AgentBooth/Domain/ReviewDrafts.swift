import Foundation

/// レビュー画面での話者。`DialogueLine.speaker` の生文字列を UI 向けに正規化する。
enum ReviewSpeaker: String, CaseIterable, Identifiable, Sendable {
    case male
    case female

    var id: String { rawValue }

    /// UI 表示名（日本語）。
    var displayName: String {
        switch self {
        case .male: return String(localized: "男性")
        case .female: return String(localized: "女性")
        }
    }

    /// TTS トランスクリプト上のラベル。`TTSInputComposer` の既存挙動に合わせる。
    var transcriptLabel: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        }
    }

    /// `DialogueLine.speaker` の生文字列から変換する。"male" 以外はすべて女性扱い（既存の `GeminiTTSService` の挙動に合わせる）。
    init(rawSpeaker: String) {
        self = rawSpeaker == "male" ? .male : .female
    }

    /// もう一方の話者。
    var toggled: ReviewSpeaker {
        self == .male ? .female : .male
    }
}

/// レビュー画面で編集する1発話行のドラフト。`DialogueLine` に安定 ID を持たせるための UI 専用モデル。
struct ReviewLineDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var speaker: ReviewSpeaker
    var text: String

    init(id: UUID = UUID(), speaker: ReviewSpeaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }

    init(dialogue: DialogueLine) {
        self.id = UUID()
        self.speaker = ReviewSpeaker(rawSpeaker: dialogue.speaker)
        self.text = dialogue.text
    }

    var asDialogueLine: DialogueLine {
        DialogueLine(speaker: speaker == .male ? "male" : "female", text: text)
    }
}

/// レビュー画面で編集する1セグメント分のドラフト。
struct ReviewSegmentDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let segmentKey: String
    let segmentLabel: String
    let maleVoiceName: String
    let femaleVoiceName: String
    /// 元の `RadioScript`。`segmentType` / `summaryBullets` / `track` を保持するために持つ。
    let originalScript: RadioScript
    var sceneDirection: String
    var lines: [ReviewLineDraft]
    var pronunciationEntries: [PronunciationEntry]

    init(item: ReviewScriptItem) {
        self.id = UUID()
        self.segmentKey = item.segmentKey
        self.segmentLabel = item.segmentLabel
        self.maleVoiceName = item.maleVoiceName
        self.femaleVoiceName = item.femaleVoiceName
        self.originalScript = item.script
        self.sceneDirection = item.sceneDirection
        self.lines = item.script.dialogues.map { ReviewLineDraft(dialogue: $0) }
        self.pronunciationEntries = item.pronunciationEntries
    }

    /// 承認時に呼び出し元 index を割り当てて `ReviewScriptItem` へ変換する。
    /// `droppingEmptyLines` が true の場合、テキストが空（trim後）の行を除外する。
    func makeReviewScriptItem(id: Int, droppingEmptyLines: Bool) -> ReviewScriptItem {
        var effectiveLines = lines
        if droppingEmptyLines {
            let filtered = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            effectiveLines = filtered.isEmpty ? lines : filtered
        }
        let updatedScript = RadioScript(
            segmentType: originalScript.segmentType,
            dialogues: effectiveLines.map(\.asDialogueLine),
            summaryBullets: originalScript.summaryBullets,
            track: originalScript.track
        )
        return ReviewScriptItem(
            id: id,
            segmentKey: segmentKey,
            segmentLabel: segmentLabel,
            script: updatedScript,
            sceneDirection: sceneDirection,
            pronunciationEntries: pronunciationEntries,
            maleVoiceName: maleVoiceName,
            femaleVoiceName: femaleVoiceName
        )
    }

    var dialogueLines: [DialogueLine] {
        lines.map(\.asDialogueLine)
    }
}

/// 末端テキストエディタの再シード判定キー。これが変わったときだけ外部値でエディタの内容を上書きする。
struct ReviewSeedToken: Hashable, Sendable {
    let targetID: UUID
    let structureRevision: Int
}

/// 検索・置換のヒット1件。
struct ReviewMatch: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case sceneDirection
        case line(UUID)
    }

    let segmentID: UUID
    let target: Target
    /// UTF-16 オフセットに基づく範囲。
    let range: NSRange
}

/// 検索・置換バーの状態。
struct ReviewSearchState: Equatable, Sendable {
    var query: String = ""
    var replacement: String = ""
    var isCaseSensitive: Bool = false
    var isBarShown: Bool = false
    /// 現在フォーカスされているヒットの index。-1 は「まだどのヒットへもジャンプしていない」センチネル。
    var currentMatchIndex: Int = -1
}

/// 承認前バリデーションの警告。
enum ReviewValidationIssue: Equatable, Sendable {
    case emptyLine(segmentID: UUID, lineID: UUID)
    case emptySegment(segmentID: UUID)

    var message: String {
        switch self {
        case .emptyLine:
            return String(localized: "空の発話行があります")
        case .emptySegment:
            return String(localized: "発話行が1件もないセグメントがあります")
        }
    }
}
