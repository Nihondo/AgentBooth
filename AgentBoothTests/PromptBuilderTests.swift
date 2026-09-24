import XCTest
@testable import AgentBooth

final class PromptBuilderTests: XCTestCase {
    private func makeTrack(name: String = "曲名") -> TrackInfo {
        TrackInfo(name: name, artist: "アーティスト", album: "アルバム")
    }

    private func makeSettings(modelName: String) -> AppSettings {
        var settings = AppSettings()
        settings.ttsCredentialSets = [TTSCredentialSet(label: "main", apiKey: "key", modelName: modelName)]
        return settings
    }

    /// アクティブな TTS モデルが Gemini 3.8 以降のときだけ、インライン発話タグの使用ルールを
    /// 台本生成プロンプトへ含める。3.8 は本文中のタグを演技指示として解釈できるが、
    /// 2.5 / 3.1 はそのまま読み上げてしまうため案内しない
    /// （`TTSInputComposer.stripInlineVocalTags` が旧モデル向けの保険として除去する）。
    func testOpeningPromptIncludesInlineTagRuleOnlyForGemini38Model() {
        let tracks = [makeTrack()]

        let withGemini38 = PromptBuilder.buildOpeningPrompt(tracks: tracks, settings: makeSettings(modelName: "gemini-3.8-flash-tts"))
        XCTAssertTrue(withGemini38.contains("<laugh>"))

        let withLegacy = PromptBuilder.buildOpeningPrompt(tracks: tracks, settings: makeSettings(modelName: "gemini-2.5-flash-preview-tts"))
        XCTAssertFalse(withLegacy.contains("<laugh>"))
    }

    func testTransitionPromptIncludesInlineTagRuleOnlyForGemini38Model() {
        let withGemini38 = PromptBuilder.buildTransitionPrompt(
            currentTrack: makeTrack(name: "曲A"),
            nextTrack: makeTrack(name: "曲B"),
            settings: makeSettings(modelName: "gemini-3.8-flash-tts"),
            continuityNote: nil
        )
        XCTAssertTrue(withGemini38.contains("<laugh>"))

        let withLegacy = PromptBuilder.buildTransitionPrompt(
            currentTrack: makeTrack(name: "曲A"),
            nextTrack: makeTrack(name: "曲B"),
            settings: makeSettings(modelName: "gemini-3.1-flash-tts-preview"),
            continuityNote: nil
        )
        XCTAssertFalse(withLegacy.contains("<laugh>"))
    }

    func testClosingPromptIncludesInlineTagRuleOnlyForGemini38Model() {
        let tracks = [makeTrack()]

        let withGemini38 = PromptBuilder.buildClosingPrompt(tracks: tracks, settings: makeSettings(modelName: "gemini-3.8-flash-lite-tts"))
        XCTAssertTrue(withGemini38.contains("<laugh>"))

        let withLegacy = PromptBuilder.buildClosingPrompt(tracks: tracks, settings: makeSettings(modelName: "gemini-2.5-pro-preview-tts"))
        XCTAssertFalse(withLegacy.contains("<laugh>"))
    }
}
