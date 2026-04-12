import Darwin
import Foundation

enum SystemAudioPlaybackError: LocalizedError {
    case launchFailed(String)
    case playbackFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "トーク音声の再生を開始できませんでした: \(detail)"
        case .playbackFailed(let status):
            return "トーク音声の再生が失敗しました。(afplay exit=\(status))"
        }
    }
}

actor SystemAudioPlaybackService: AudioPlaybackServiceProtocol {
    private let fileManager: FileManager
    private var playbackProcess: Process?
    private var playbackFileURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var isPaused = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func play(wavData: Data) async throws {
        await stopPlayback()

        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try wavData.write(to: fileURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [fileURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(
                    status: terminatedProcess.terminationStatus,
                    fileURL: fileURL
                )
            }
        }

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw SystemAudioPlaybackError.launchFailed(error.localizedDescription)
        }

        playbackProcess = process
        playbackFileURL = fileURL
        isPaused = false

        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func stopPlayback() async {
        playbackProcess?.terminate()
        playbackProcess = nil
        isPaused = false
        cleanupPlaybackFile()
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func pausePlayback() async {
        guard let playbackProcess, playbackProcess.isRunning else {
            return
        }
        kill(playbackProcess.processIdentifier, SIGSTOP)
        isPaused = true
    }

    func resumePlayback() async {
        guard let playbackProcess, playbackProcess.isRunning else {
            return
        }
        kill(playbackProcess.processIdentifier, SIGCONT)
        isPaused = false
    }

    func fetchIsPlaying() async -> Bool {
        guard let playbackProcess else {
            return false
        }
        return playbackProcess.isRunning && !isPaused
    }

    private func handleTermination(status: Int32, fileURL: URL) {
        playbackProcess = nil
        playbackFileURL = nil
        isPaused = false
        try? fileManager.removeItem(at: fileURL)

        guard let finishContinuation else {
            return
        }
        self.finishContinuation = nil

        if status == 0 || status == SIGTERM {
            finishContinuation.resume()
        } else {
            finishContinuation.resume(throwing: SystemAudioPlaybackError.playbackFailed(status))
        }
    }

    private func cleanupPlaybackFile() {
        guard let playbackFileURL else {
            return
        }
        try? fileManager.removeItem(at: playbackFileURL)
        self.playbackFileURL = nil
    }
}
