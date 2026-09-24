import XCTest
@testable import AgentBooth

final class GeminiTTSRequestSchemaTests: XCTestCase {
    func testLegacyModelsUseLegacyPromptSchema() {
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-2.5-flash-preview-tts"), .legacyPrompt)
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-2.5-pro-preview-tts"), .legacyPrompt)
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-3.1-flash-tts-preview"), .legacyPrompt)
    }

    /// バージョン表記から判定できないモデル名（テスト用ダミー名など）は legacy 側へフォールバックする。
    func testUnrecognizedModelNameFallsBackToLegacyPromptSchema() {
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("test-model"), .legacyPrompt)
        XCTAssertEqual(GeminiTTSRequestSchema.forModel(""), .legacyPrompt)
    }

    func testGemini38ModelsUseSpeechMetadataSchema() {
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-3.8-flash-tts"), .speechMetadata)
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-3.8-flash-lite-tts"), .speechMetadata)
    }

    /// 将来登場するモデルも新スキーマ側に倒す: メジャーバージョンだけが上がった名前
    /// （マイナーなし）や、より大きいマイナーバージョンも `.speechMetadata` と判定する。
    func testFutureModelVersionsUseSpeechMetadataSchema() {
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-4-flash-tts"), .speechMetadata)
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-3.10-flash-tts"), .speechMetadata)
        XCTAssertEqual(GeminiTTSRequestSchema.forModel("gemini-3.9-flash-tts"), .speechMetadata)
    }
}
