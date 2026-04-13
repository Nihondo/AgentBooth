import Foundation

enum ScriptGenerationError: LocalizedError {
    case unsupportedCLI
    case invalidOutput
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCLI:
            return "未対応の CLI が指定されました。"
        case .invalidOutput:
            return "スクリプト生成結果を JSON として解釈できませんでした。"
        case .processFailed(let detail):
            return detail
        }
    }
}

struct ScriptCommandBuilder {
    func makeCommand(prompt: String, settings: AppSettings) throws -> [String] {
        switch settings.scriptCLIKind {
        case .claude:
            return addModelArgument(
                baseCommand: ["claude", "-p", prompt, "--output-format", "text"],
                settings: settings,
                optionName: "--model"
            )
        case .gemini:
            return addModelArgument(
                baseCommand: ["gemini", "-p", prompt],
                settings: settings,
                optionName: "--model"
            )
        case .codex:
            var baseCommand = ["codex", "exec", "--skip-git-repo-check"]
            if !settings.scriptCLIModel.isEmpty {
                baseCommand.append("--model=\(settings.scriptCLIModel)")
            }
            baseCommand.append(prompt)
            return baseCommand
        case .copilot:
            return addModelArgument(
                baseCommand: ["copilot", "-p", prompt],
                settings: settings,
                optionName: "--model"
            )
        }
    }

    private func addModelArgument(
        baseCommand: [String],
        settings: AppSettings,
        optionName: String
    ) -> [String] {
        guard !settings.scriptCLIModel.isEmpty else {
            return baseCommand
        }
        var command = baseCommand
        command.append(contentsOf: [optionName, settings.scriptCLIModel])
        return command
    }
}

struct ScriptProcessEnvironmentBuilder {
    private let supplementalPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.bun/bin",
    ]

    func makeEnvironment(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = baseEnvironment
        let currentPathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        var mergedPathEntries = currentPathEntries
        for pathEntry in supplementalPathEntries where !mergedPathEntries.contains(pathEntry) {
            mergedPathEntries.append(pathEntry)
        }

        environment["PATH"] = mergedPathEntries.joined(separator: ":")
        return environment
    }
}

struct ScriptProcessLaunchSpec {
    let executableURL: URL
    let arguments: [String]
}

struct ScriptProcessLaunchBuilder {
    func makeLaunchSpec(command: [String], environment: [String: String]) throws -> ScriptProcessLaunchSpec {
        guard let executableName = command.first else {
            throw ScriptGenerationError.unsupportedCLI
        }

        if let executablePath = resolveExecutablePath(named: executableName, environment: environment) {
            let arguments = Array(command.dropFirst())
            return ScriptProcessLaunchSpec(executableURL: URL(fileURLWithPath: executablePath), arguments: arguments)
        }

        let shellCommand = command.map(makeShellSafeArgument(_:)).joined(separator: " ")
        return ScriptProcessLaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", shellCommand]
        )
    }

    private func resolveExecutablePath(named executableName: String, environment: [String: String]) -> String? {
        if executableName.contains("/") {
            return FileManager.default.isExecutableFile(atPath: executableName) ? executableName : nil
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for pathEntry in pathEntries {
            let candidatePath = URL(fileURLWithPath: pathEntry)
                .appendingPathComponent(executableName)
                .path
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }

        return nil
    }

    private func makeShellSafeArgument(_ value: String) -> String {
        let escapedValue = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escapedValue)'"
    }
}

private struct DialogueEnvelope: Decodable {
    let dialogues: [DialogueLine]
}

private struct ScriptEnvelope: Decodable {
    let dialogues: [DialogueLine]
    let summaryBullets: [String]?
}

private struct ScriptLogSession {
    let directoryURL: URL
}

/// Generates radio scripts by shelling out to an external CLI tool.
final class ProcessScriptGenerationService: @unchecked Sendable, ScriptGenerationService {
    private let commandBuilder = ScriptCommandBuilder()
    private let environmentBuilder = ScriptProcessEnvironmentBuilder()
    private let launchBuilder = ScriptProcessLaunchBuilder()
    private let fileManager: FileManager
    private var sessionLog: ScriptLogSession?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func generateOpening(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        try await generateSegment(
            segmentType: "opening",
            label: tracks.first?.name ?? "opening",
            prompt: PromptBuilder.buildOpeningPrompt(tracks: tracks, settings: settings),
            track: tracks.first,
            settings: settings
        )
    }

    func generateTransition(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        settings: AppSettings,
        continuityNote: String?
    ) async throws -> RadioScript {
        try await generateSegment(
            segmentType: "transition",
            label: "\(currentTrack.name)_to_\(nextTrack.name)",
            prompt: PromptBuilder.buildTransitionPrompt(
                currentTrack: currentTrack,
                nextTrack: nextTrack,
                settings: settings,
                continuityNote: continuityNote
            ),
            track: nextTrack,
            settings: settings
        )
    }

    func generateClosing(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        try await generateSegment(
            segmentType: "closing",
            label: tracks.last?.name ?? "closing",
            prompt: PromptBuilder.buildClosingPrompt(tracks: tracks, settings: settings),
            track: tracks.last,
            settings: settings
        )
    }

    private func generateSegment(
        segmentType: String,
        label: String,
        prompt: String,
        track: TrackInfo?,
        settings: AppSettings
    ) async throws -> RadioScript {
        let rawOutput = try runCLI(prompt: prompt, settings: settings)
        do {
            let parsedScript = try parseRadioScript(from: rawOutput)
            try saveLog(
                segmentType: segmentType,
                label: label,
                prompt: prompt,
                rawOutput: rawOutput,
                dialogues: parsedScript.dialogues,
                summaryBullets: parsedScript.summaryBullets,
                error: nil
            )
            return RadioScript(
                segmentType: segmentType,
                dialogues: parsedScript.dialogues,
                summaryBullets: parsedScript.summaryBullets,
                track: track
            )
        } catch {
            try? saveLog(
                segmentType: segmentType,
                label: label,
                prompt: prompt,
                rawOutput: rawOutput,
                dialogues: [],
                summaryBullets: [],
                error: error
            )
            throw error
        }
    }

    private func runCLI(prompt: String, settings: AppSettings) throws -> String {
        let command = try commandBuilder.makeCommand(prompt: prompt, settings: settings)
        guard let executableName = command.first else { throw ScriptGenerationError.unsupportedCLI }
        let environment = environmentBuilder.makeEnvironment()
        let launchSpec = try launchBuilder.makeLaunchSpec(command: command, environment: environment)

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = launchSpec.executableURL
        process.arguments = launchSpec.arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = nil
        process.currentDirectoryURL = (try? makeSessionLog())?.directoryURL

        do {
            try process.run()
        } catch {
            throw ScriptGenerationError.processFailed("\(executableName) CLI を起動できませんでした: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let outputText = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScriptGenerationError.processFailed(detail.isEmpty ? "\(executableName) CLI の実行に失敗しました。" : detail)
        }

        return outputText
    }

    private func parseRadioScript(from rawOutput: String) throws -> (dialogues: [DialogueLine], summaryBullets: [String]) {
        let extractedJSON = extractJSONPayload(from: rawOutput)
        let payloadData = Data(extractedJSON.utf8)

        if let envelope = try? JSONDecoder().decode(ScriptEnvelope.self, from: payloadData) {
            return (
                dialogues: validate(dialogues: envelope.dialogues),
                summaryBullets: normalizeSummaryBullets(envelope.summaryBullets ?? [])
            )
        }

        if let envelope = try? JSONDecoder().decode(DialogueEnvelope.self, from: payloadData) {
            return (dialogues: validate(dialogues: envelope.dialogues), summaryBullets: [])
        }

        if let dialogues = try? JSONDecoder().decode([DialogueLine].self, from: payloadData) {
            return (dialogues: validate(dialogues: dialogues), summaryBullets: [])
        }

        throw ScriptGenerationError.invalidOutput
    }

    private func extractJSONPayload(from rawOutput: String) -> String {
        if let fencedRange = rawOutput.range(of: "```json") ?? rawOutput.range(of: "```") {
            let suffixText = rawOutput[fencedRange.upperBound...]
            if let closingRange = suffixText.range(of: "```") {
                return suffixText[..<closingRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let objectStart = rawOutput.firstIndex(of: "{"), let objectEnd = rawOutput.lastIndex(of: "}") {
            return String(rawOutput[objectStart...objectEnd])
        }

        if let arrayStart = rawOutput.firstIndex(of: "["), let arrayEnd = rawOutput.lastIndex(of: "]") {
            return String(rawOutput[arrayStart...arrayEnd])
        }

        return rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validate(dialogues: [DialogueLine]) -> [DialogueLine] {
        let speakers = Set(dialogues.map(\.speaker))
        guard speakers == Set(["male", "female"]) else {
            return dialogues
        }
        return dialogues
    }

    private func normalizeSummaryBullets(_ summaryBullets: [String]) -> [String] {
        var normalizedBullets: [String] = []
        for bullet in summaryBullets {
            let normalizedBullet = bullet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedBullet.isEmpty else {
                continue
            }
            if !normalizedBullets.contains(normalizedBullet) {
                normalizedBullets.append(normalizedBullet)
            }
        }
        return normalizedBullets
    }

    private func saveLog(
        segmentType: String,
        label: String,
        prompt: String,
        rawOutput: String,
        dialogues: [DialogueLine],
        summaryBullets: [String],
        error: Error?
    ) throws {
        let session = try makeSessionLog()
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "\(timestamp)_\(segmentType)_\(safeFileName(label)).md"
        let fileURL = session.directoryURL.appendingPathComponent(fileName)

        let dialogueText = dialogues.map { "**\($0.speaker)**: \($0.text)" }.joined(separator: "\n")
        let summaryText = summaryBullets.isEmpty ? "- なし" : summaryBullets.map { "- \($0)" }.joined(separator: "\n")
        let errorBlock = error.map { "\n## Error\n\n\($0.localizedDescription)\n" } ?? ""
        let content = """
        # \(segmentType.uppercased()) — \(label)

        ## Prompt

        ```
        \(prompt)
        ```

        ## Parsed Dialogues

        \(dialogueText)

        ## Parsed Summary

        \(summaryText)
        \(errorBlock)
        ## Raw Output

        ```
        \(rawOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        ```
        """

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func makeSessionLog() throws -> ScriptLogSession {
        if let sessionLog {
            return sessionLog
        }

        let baseDirectory = try applicationSupportDirectory()
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let sessionDirectory = baseDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let sessionLog = ScriptLogSession(directoryURL: sessionDirectory)
        self.sessionLog = sessionLog
        return sessionLog
    }

    private func applicationSupportDirectory() throws -> URL {
        let directoryURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = directoryURL.appendingPathComponent("AgentBooth", isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory
    }

    private func safeFileName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return value.components(separatedBy: invalidCharacters).joined(separator: "_").prefix(40).description
    }
}
