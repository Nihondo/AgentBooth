import CryptoKit
import XCTest
@testable import AgentBooth

final class NarrationAudioFingerprintTests: XCTestCase {
    private func makeDialogues() -> [DialogueLine] {
        [
            DialogueLine(speaker: "male", text: "こんばんは"),
            DialogueLine(speaker: "female", text: "今夜も始めていきます"),
        ]
    }

    private func makeSettings(
        sceneDirection: String = "深夜帯、静かに話す",
        maleVoiceName: String = "Charon",
        femaleVoiceName: String = "Kore",
        modelName: String = "test-model"
    ) -> AppSettings {
        var settings = AppSettings()
        settings.directionSettings.sceneDirection = sceneDirection
        settings.voiceSettings.maleVoiceName = maleVoiceName
        settings.voiceSettings.femaleVoiceName = femaleVoiceName
        settings.ttsCredentialSets = [TTSCredentialSet(label: "main", apiKey: "key", modelName: modelName)]
        return settings
    }

    func testSameInputProducesSameFingerprint() {
        let dialogues = makeDialogues()
        let settings = makeSettings()

        let first = NarrationAudioFingerprint.make(dialogues: dialogues, settings: settings)
        let second = NarrationAudioFingerprint.make(dialogues: dialogues, settings: settings)

        XCTAssertEqual(first, second)
    }

    /// 永続キーの安定性そのものが仕様: `Hasher` へ退行するとプロセスごとに値が変わり、
    /// このテストが落ちる。
    func testMatchesGoldenValue() {
        let fingerprint = NarrationAudioFingerprint.make(dialogues: makeDialogues(), settings: makeSettings())
        XCTAssertEqual(fingerprint, "43c1c757aad25ce288c211afdc1fa673a6dde89e9b19b9e754de692f7271a719")
    }

    func testChangingDialogueTextChangesFingerprint() {
        let settings = makeSettings()
        let base = NarrationAudioFingerprint.make(dialogues: makeDialogues(), settings: settings)

        let changed = [
            DialogueLine(speaker: "male", text: "こんばんは、変更後"),
            DialogueLine(speaker: "female", text: "今夜も始めていきます"),
        ]
        let changedFingerprint = NarrationAudioFingerprint.make(dialogues: changed, settings: settings)

        XCTAssertNotEqual(base, changedFingerprint)
    }

    func testChangingSpeakerChangesFingerprint() {
        let settings = makeSettings()
        let base = NarrationAudioFingerprint.make(dialogues: makeDialogues(), settings: settings)

        let changed = [
            DialogueLine(speaker: "female", text: "こんばんは"),
            DialogueLine(speaker: "female", text: "今夜も始めていきます"),
        ]
        let changedFingerprint = NarrationAudioFingerprint.make(dialogues: changed, settings: settings)

        XCTAssertNotEqual(base, changedFingerprint)
    }

    func testChangingSceneDirectionChangesFingerprint() {
        let dialogues = makeDialogues()
        let base = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings())
        let changed = NarrationAudioFingerprint.make(
            dialogues: dialogues,
            settings: makeSettings(sceneDirection: "朝、元気に話す")
        )

        XCTAssertNotEqual(base, changed)
    }

    func testChangingPronunciationDictionaryChangesFingerprint() {
        let dialogues = [DialogueLine(speaker: "male", text: "女神転生の話をします")]
        let withoutEntry = makeSettings()
        var withEntry = makeSettings()
        withEntry.globalPronunciationEntries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]

        let base = NarrationAudioFingerprint.make(dialogues: dialogues, settings: withoutEntry)
        let changed = NarrationAudioFingerprint.make(dialogues: dialogues, settings: withEntry)

        XCTAssertNotEqual(base, changed)
    }

    func testChangingPronunciationApplicationModeChangesFingerprint() {
        let dialogues = [DialogueLine(speaker: "male", text: "女神転生の話をします")]
        var settings = makeSettings()
        settings.globalPronunciationEntries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]

        let instructionMode = NarrationAudioFingerprint.make(dialogues: dialogues, settings: settings)
        settings.directionSettings.pronunciationApplicationMode = .replaceTranscript
        let replaceMode = NarrationAudioFingerprint.make(dialogues: dialogues, settings: settings)

        XCTAssertNotEqual(instructionMode, replaceMode)
    }

    func testChangingMaleVoiceNameChangesFingerprint() {
        let dialogues = makeDialogues()
        let base = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings())
        let changed = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings(maleVoiceName: "Puck"))

        XCTAssertNotEqual(base, changed)
    }

    func testChangingFemaleVoiceNameChangesFingerprint() {
        let dialogues = makeDialogues()
        let base = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings())
        let changed = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings(femaleVoiceName: "Puck"))

        XCTAssertNotEqual(base, changed)
    }

    func testChangingModelNameChangesFingerprint() {
        let dialogues = makeDialogues()
        let base = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings())
        let changed = NarrationAudioFingerprint.make(dialogues: dialogues, settings: makeSettings(modelName: "other-model"))

        XCTAssertNotEqual(base, changed)
    }

    /// legacy スキーマ（`test-model`）のフィンガープリントは 3.8 対応前とバイト単位で同一でなければならない。
    /// これが崩れると、既存ユーザーの 2.5 / 3.1 音声キャッシュが今回の変更だけで全て無効化されてしまう。
    func testLegacyModelFingerprintUnchangedByMigration() {
        let fingerprint = NarrationAudioFingerprint.make(dialogues: makeDialogues(), settings: makeSettings())
        XCTAssertEqual(fingerprint, "43c1c757aad25ce288c211afdc1fa673a6dde89e9b19b9e754de692f7271a719")
    }

    /// 単一話者・sceneDirection 空の場合、speechMetadata のプレビュー文字列は legacy の
    /// `makeInput` 結果と完全に一致する（どちらも台詞テキストのみ）。このケースでスキーマを
    /// フィンガープリントへ含めなければ、3.8 移行前に生成された不正なキャッシュと衝突してしまう。
    func testSpeechMetadataFingerprintDiffersFromNaiveFormulaEvenWhenPreviewTextMatchesLegacy() {
        let dialogues = [DialogueLine(speaker: "male", text: "こんにちは")]
        var settings = AppSettings()
        settings.directionSettings.sceneDirection = ""
        settings.voiceSettings.maleVoiceName = "Charon"
        settings.voiceSettings.femaleVoiceName = "Kore"
        settings.ttsCredentialSets = [TTSCredentialSet(label: "main", apiKey: "key", modelName: "gemini-3.8-flash-tts")]

        let actual = NarrationAudioFingerprint.make(dialogues: dialogues, settings: settings)

        let previewText = TTSInputComposer.makePreviewText(
            dialogues: dialogues,
            directionSettings: settings.directionSettings,
            pronunciationEntries: [],
            schema: .speechMetadata
        )
        // 前提の確認: このケースでは speechMetadata のプレビューが legacy の makeInput と同一文字列になる。
        XCTAssertEqual(previewText, "こんにちは")

        let naivePayload = [previewText, "Charon", "Kore", "gemini-3.8-flash-tts"].joined(separator: "\u{1F}")
        let naiveDigest = SHA256.hash(data: Data(naivePayload.utf8)).map { String(format: "%02x", $0) }.joined()

        XCTAssertNotEqual(actual, naiveDigest)
    }
}
