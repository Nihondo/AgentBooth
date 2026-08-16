import XCTest
@testable import AgentBooth

final class TTSInputComposerTests: XCTestCase {
    private let dialogues = [
        DialogueLine(speaker: "male", text: "ファミコン版「女神転生」から"),
        DialogueLine(speaker: "female", text: "エンディングテーマをお届けします"),
    ]

    func testMakeInputWithDirectionOnlyMatchesGoldenValue() {
        let directionSettings = DirectionSettings(sceneDirection: "深夜帯、静かに話す")
        let result = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: directionSettings)

        let expected = """
        Direction:
        深夜帯、静かに話す

        Male: ファミコン版「女神転生」から
        Female: エンディングテーマをお届けします
        """
        XCTAssertEqual(result, expected)
    }

    func testMakeInputOmitsDirectionBlockWhenSceneDirectionIsEmpty() {
        let result = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: DirectionSettings())
        let expected = "Male: ファミコン版「女神転生」から\nFemale: エンディングテーマをお届けします"
        XCTAssertEqual(result, expected)
    }

    /// 辞書エントリが1つも台詞に出現しない場合、辞書ブロックは完全に省略され、
    /// 出力は辞書機能が存在しない場合と1バイトも変わらない（既存 TTS テストの不変性を守る仕様）。
    func testMakeInputOmitsPronunciationBlockWhenNoEntryAppearsInDialogues() {
        let entries = [PronunciationEntry(source: "存在しない語", reading: "そんざいしないご")]
        let withEntries = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: DirectionSettings(), pronunciationEntries: entries)
        let withoutEntries = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: DirectionSettings())
        XCTAssertEqual(withEntries, withoutEntries)
    }

    func testMakeInputOrdersDirectionThenPronunciationThenTranscript() {
        let directionSettings = DirectionSettings(sceneDirection: "深夜帯")
        let entries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]

        let result = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: directionSettings, pronunciationEntries: entries)

        let expected = """
        Direction:
        深夜帯

        Follow these pronunciation rules exactly.
        These rules affect pronunciation only. Do not alter the transcript.

        Pronunciation dictionary:
        「女神転生」 = 「メガミテンセイ」

        Male: ファミコン版「女神転生」から
        Female: エンディングテーマをお届けします
        """
        XCTAssertEqual(result, expected)
    }

    func testMakeInputListsOnlyEntriesThatAppearInDialogues() {
        let entries = [
            PronunciationEntry(source: "女神転生", reading: "メガミテンセイ"),
            PronunciationEntry(source: "存在しない語", reading: "そんざいしないご"),
        ]
        let result = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: DirectionSettings(), pronunciationEntries: entries)

        XCTAssertTrue(result.contains("「女神転生」 = 「メガミテンセイ」"))
        XCTAssertFalse(result.contains("存在しない語"))
    }

    func testReplacementModeReplacesEveryOccurrenceAndKeepsDirection() {
        let dialogues = [DialogueLine(speaker: "male", text: "女神転生から女神転生へ")]
        let directionSettings = DirectionSettings(
            sceneDirection: "静かに話す",
            pronunciationApplicationMode: .replaceTranscript
        )
        let entries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]

        let result = TTSInputComposer.makeInput(
            dialogues: dialogues,
            directionSettings: directionSettings,
            pronunciationEntries: entries
        )

        XCTAssertEqual(result, "Direction:\n静かに話す\n\nメガミテンセイからメガミテンセイへ")
        XCTAssertFalse(result.contains("Pronunciation dictionary"))
    }

    func testReplacementModeUsesLongestMatchAtSamePosition() {
        let entries = [
            PronunciationEntry(source: "女神", reading: "めがみ"),
            PronunciationEntry(source: "女神転生", reading: "メガテン"),
        ]

        let result = TTSInputComposer.replacePronunciations(in: "女神転生", entries: entries)

        XCTAssertEqual(result, "メガテン")
    }

    func testReplacementModeDoesNotRecursivelyReplaceInsertedReading() {
        let entries = [
            PronunciationEntry(source: "A", reading: "B"),
            PronunciationEntry(source: "B", reading: "C"),
        ]

        let result = TTSInputComposer.replacePronunciations(in: "A", entries: entries)

        XCTAssertEqual(result, "B")
    }

    func testReplacementModeUsesLastDuplicateEntry() {
        let entries = [
            PronunciationEntry(source: "Ys", reading: "ワイエス"),
            PronunciationEntry(source: "Ys", reading: "イース"),
        ]

        let result = TTSInputComposer.replacePronunciations(in: "Ys", entries: entries)

        XCTAssertEqual(result, "イース")
    }

    func testReplacementModeMatchesCanonicallyEquivalentText() {
        let entries = [PronunciationEntry(source: "Café", reading: "カフェ")]

        let result = TTSInputComposer.replacePronunciations(in: "Cafe\u{301}です", entries: entries)

        XCTAssertEqual(result, "カフェです")
    }

    func testReplacementModeIgnoresDisabledAndEmptyEntries() {
        let entries = [
            PronunciationEntry(source: "女神転生", reading: "メガテン", isEnabled: false),
            PronunciationEntry(source: "", reading: "から"),
            PronunciationEntry(source: "女神転生", reading: ""),
        ]

        let result = TTSInputComposer.replacePronunciations(in: "女神転生", entries: entries)

        XCTAssertEqual(result, "女神転生")
    }

    func testMakeInputExcludesDisabledEntries() {
        let entries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ", isEnabled: false)]
        let result = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: DirectionSettings(), pronunciationEntries: entries)
        XCTAssertFalse(result.contains("Pronunciation dictionary"))
    }

    func testMakeInputExcludesEntriesWithEmptySourceOrReading() {
        let entries = [
            PronunciationEntry(source: "", reading: "からのそうき"),
            // "女神転生" は台詞中に実際に出現するが、読みが空なので出力してはいけない。
            PronunciationEntry(source: "女神転生", reading: ""),
        ]
        let result = TTSInputComposer.makeInput(dialogues: dialogues, directionSettings: DirectionSettings(), pronunciationEntries: entries)
        XCTAssertFalse(result.contains("Pronunciation dictionary"))
    }

    /// 2話者以上の入力ではラベルが付くため、未知の話者が Female へ正規化されることを検証できる
    /// （単一話者の入力ではそもそもラベルが付かないため、2行構成にする必要がある）。
    func testMakeTranscriptNormalizesUnknownSpeakerToFemale() {
        let mixedDialogues = [
            DialogueLine(speaker: "male", text: "男性の台詞"),
            DialogueLine(speaker: "narrator", text: "地の文"),
        ]
        let transcript = TTSInputComposer.makeTranscript(dialogues: mixedDialogues)
        XCTAssertEqual(transcript, "Male: 男性の台詞\nFemale: 地の文")
    }

    func testMakeTranscriptOmitsSpeakerLabelForSingleSpeakerInput() {
        let maleOnly = [DialogueLine(speaker: "male", text: "男性だけの台詞")]
        XCTAssertEqual(TTSInputComposer.makeTranscript(dialogues: maleOnly), "男性だけの台詞")

        let femaleOnly = [DialogueLine(speaker: "female", text: "女性だけの台詞")]
        XCTAssertEqual(TTSInputComposer.makeTranscript(dialogues: femaleOnly), "女性だけの台詞")
    }

    func testMakeTranscriptKeepsSpeakerLabelsForMultipleSpeakers() {
        let dialogues = [
            DialogueLine(speaker: "male", text: "こんにちは"),
            DialogueLine(speaker: "female", text: "こんばんは"),
        ]
        XCTAssertEqual(
            TTSInputComposer.makeTranscript(dialogues: dialogues),
            "Male: こんにちは\nFemale: こんばんは"
        )
    }

    func testSpeakerLabelsReturnsDistinctLabelsInAppearanceOrder() {
        let dialogues = [
            DialogueLine(speaker: "female", text: "1"),
            DialogueLine(speaker: "male", text: "2"),
            DialogueLine(speaker: "female", text: "3"),
        ]
        XCTAssertEqual(TTSInputComposer.speakerLabels(in: dialogues), ["Female", "Male"])
    }

    func testSpeakerLabelsReturnsEmptyForNoDialogues() {
        XCTAssertEqual(TTSInputComposer.speakerLabels(in: []), [])
    }

    func testAppliesToDetectsSubstringMatch() {
        let entry = PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")
        XCTAssertTrue(TTSInputComposer.appliesTo(entry: entry, dialogues: dialogues))
    }

    func testAppliesToReturnsFalseWhenSourceDoesNotAppear() {
        let entry = PronunciationEntry(source: "存在しない語", reading: "そんざいしないご")
        XCTAssertFalse(TTSInputComposer.appliesTo(entry: entry, dialogues: dialogues))
    }
}
