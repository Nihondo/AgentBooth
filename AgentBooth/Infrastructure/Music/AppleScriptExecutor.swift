import Foundation

enum AppleScriptExecutorError: LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        }
    }
}

/// Executes AppleScript through osascript.
final class AppleScriptExecutor: @unchecked Sendable {
    func run(script: String) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw AppleScriptExecutorError.executionFailed(errorText.isEmpty ? "AppleScript execution failed." : errorText)
        }

        return outputText
    }
}
