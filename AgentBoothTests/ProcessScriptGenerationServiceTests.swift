import XCTest
@testable import AgentBooth

final class ProcessScriptGenerationServiceTests: XCTestCase {
    func testGenerateOpeningParsesDialoguesAndSummaryBullets() async throws {
        let rawOutput = """
        {
          "dialogues": [
            { "speaker": "male", "text": "一曲目の話をしましょう" },
            { "speaker": "female", "text": "今日は春っぽい選曲ですね" }
          ],
          "summaryBullets": [
            "春らしい選曲の導入",
            "一曲目への期待感"
          ]
        }
        """
        let service = try makeService(rawOutput: rawOutput)
        var settings = AppSettings()
        settings.scriptCLIKind = .claude

        let script = try await service.generateOpening(
            tracks: [TrackInfo(name: "Song A", artist: "Artist A", album: "Album A")],
            settings: settings
        )

        XCTAssertEqual(script.dialogues.count, 2)
        XCTAssertEqual(script.summaryBullets, ["春らしい選曲の導入", "一曲目への期待感"])
    }

    func testGenerateOpeningAcceptsLegacyDialogueEnvelope() async throws {
        let rawOutput = """
        {
          "dialogues": [
            { "speaker": "male", "text": "従来形式です" },
            { "speaker": "female", "text": "要約はありません" }
          ]
        }
        """
        let service = try makeService(rawOutput: rawOutput)
        var settings = AppSettings()
        settings.scriptCLIKind = .claude

        let script = try await service.generateOpening(
            tracks: [TrackInfo(name: "Song A", artist: "Artist A", album: "Album A")],
            settings: settings
        )

        XCTAssertEqual(script.summaryBullets, [])
        XCTAssertEqual(script.dialogues.map(\.text), ["従来形式です", "要約はありません"])
    }

    func testGenerateOpeningAcceptsLegacyDialogueArray() async throws {
        let rawOutput = """
        [
          { "speaker": "male", "text": "配列形式です" },
          { "speaker": "female", "text": "まだ受理されます" }
        ]
        """
        let service = try makeService(rawOutput: rawOutput)
        var settings = AppSettings()
        settings.scriptCLIKind = .claude

        let script = try await service.generateOpening(
            tracks: [TrackInfo(name: "Song A", artist: "Artist A", album: "Album A")],
            settings: settings
        )

        XCTAssertEqual(script.summaryBullets, [])
        XCTAssertEqual(script.dialogues.map(\.text), ["配列形式です", "まだ受理されます"])
    }

    func testGenerateOpeningWritesCueSheetCLIEvents() async throws {
        let rawOutput = """
        {
          "dialogues": [
            { "speaker": "male", "text": "テストです" },
            { "speaker": "female", "text": "了解しました" }
          ]
        }
        """
        let cueSheetLogger = try makeCueSheetLogger()
        let service = try makeService(rawOutput: rawOutput, cueSheetLogger: cueSheetLogger)
        var settings = AppSettings()
        settings.scriptCLIKind = .claude

        _ = try await CueSheetLogContext.$currentIndentLevel.withValue(1) {
            try await service.generateOpening(
                tracks: [TrackInfo(name: "Song A", artist: "Artist A", album: "Album A")],
                settings: settings
            )
        }

        let cueSheetText = try await readCueSheetText(from: cueSheetLogger)
        XCTAssertTrue(cueSheetText.contains("CLI実行開始(claude)"))
        XCTAssertTrue(cueSheetText.contains("CLI実行終了(claude / exit: 0)"))
    }

    private func makeService(
        rawOutput: String,
        cueSheetLogger: ShowCueSheetLogger? = nil
    ) throws -> ProcessScriptGenerationService {
        let service = ProcessScriptGenerationService(cueSheetLogger: cueSheetLogger)
        let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        let executableURL = temporaryDirectoryURL.appendingPathComponent("claude")
        let scriptBody = """
        #!/bin/zsh
        cat <<'EOF'
        \(rawOutput)
        EOF
        """
        try scriptBody.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(temporaryDirectoryURL.path):\(originalPath)", 1)
        addTeardownBlock {
            setenv("PATH", originalPath, 1)
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        return service
    }

    private func makeCueSheetLogger() throws -> ShowCueSheetLogger {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return ShowCueSheetLogger(sessionDirectoryURL: directoryURL)
    }

    private func readCueSheetText(from logger: ShowCueSheetLogger) async throws -> String {
        let fileURL = try await logger.cueSheetFileURL()
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
