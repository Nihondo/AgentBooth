import Foundation

enum CueSheetLogContext {
    @TaskLocal static var currentIndentLevel: Int = 0
}

/// 再生セッション中の出来事を cuesheet 形式で追記するロガー。
actor ShowCueSheetLogger {
    private let fileManager: FileManager
    private let fixedSessionDirectoryURL: URL?
    private let nowProvider: @Sendable () -> Date
    private let sessionStartedAt: Date
    private var cachedSessionDirectoryURL: URL?

    init(
        fileManager: FileManager = .default,
        sessionDirectoryURL: URL? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.fixedSessionDirectoryURL = sessionDirectoryURL
        self.nowProvider = nowProvider
        self.sessionStartedAt = nowProvider()
    }

    func sessionDirectoryURL() throws -> URL {
        if let cachedSessionDirectoryURL {
            return cachedSessionDirectoryURL
        }

        let directoryURL: URL
        if let fixedSessionDirectoryURL {
            directoryURL = fixedSessionDirectoryURL
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            directoryURL = try applicationSupportDirectory()
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent(formatter.string(from: sessionStartedAt), isDirectory: true)
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        cachedSessionDirectoryURL = directoryURL
        return directoryURL
    }

    func cueSheetFileURL() throws -> URL {
        try sessionDirectoryURL().appendingPathComponent("cuesheet.txt")
    }

    func append(
        _ message: String,
        indentLevel: Int? = nil,
        indentOffset: Int = 0
    ) async {
        do {
            let fileURL = try cueSheetFileURL()
            let actualIndentLevel = max(0, (indentLevel ?? CueSheetLogContext.currentIndentLevel) + indentOffset)
            let line = formatLine(message: message, indentLevel: actualIndentLevel)
            try appendLine(line, to: fileURL)
        } catch {
            return
        }
    }

    private func formatLine(message: String, indentLevel: Int) -> String {
        let elapsedSeconds = nowProvider().timeIntervalSince(sessionStartedAt)
        let timestamp = formatElapsedTimestamp(elapsedSeconds)
        let indent = String(repeating: "    ", count: indentLevel)
        return "[\(timestamp)] \(indent)\(message)\n"
    }

    private func formatElapsedTimestamp(_ elapsedSeconds: TimeInterval) -> String {
        let safeElapsedMilliseconds = Int(max(0, elapsedSeconds) * 1_000)
        let hours = safeElapsedMilliseconds / 3_600_000
        let minutes = (safeElapsedMilliseconds % 3_600_000) / 60_000
        let seconds = (safeElapsedMilliseconds % 60_000) / 1_000
        let milliseconds = safeElapsedMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    private func appendLine(_ line: String, to fileURL: URL) throws {
        let data = Data(line.utf8)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            return
        }

        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
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
}
