import Darwin
import Foundation

/// テストモード用音声再生サービス。
/// `play(wavData:)` の引数は無視し、
/// Application Support/AgentBooth/sample/sampletalk.m4a を `afplay` で再生する。
actor TestModeAudioPlaybackService: AudioPlaybackServiceProtocol {
    private var playbackProcess: Process?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var isPaused = false

    func play(wavData: Data) async throws {
        await stopPlayback()

        let fileURL = TestModeTTSService.sampleFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TestModeAudioPlaybackError.sampleFileNotFound(fileURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [fileURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw SystemAudioPlaybackError.launchFailed(error.localizedDescription)
        }

        playbackProcess = process
        isPaused = false

        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func stopPlayback() async {
        playbackProcess?.terminate()
        playbackProcess = nil
        isPaused = false
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func pausePlayback() async {
        guard let playbackProcess, playbackProcess.isRunning else { return }
        kill(playbackProcess.processIdentifier, SIGSTOP)
        isPaused = true
    }

    func resumePlayback() async {
        guard let playbackProcess, playbackProcess.isRunning else { return }
        kill(playbackProcess.processIdentifier, SIGCONT)
        isPaused = false
    }

    func fetchIsPlaying() async -> Bool {
        guard let playbackProcess else { return false }
        return playbackProcess.isRunning && !isPaused
    }

    private func handleTermination(status: Int32) {
        playbackProcess = nil
        isPaused = false

        guard let finishContinuation else { return }
        self.finishContinuation = nil

        if status == 0 || status == SIGTERM {
            finishContinuation.resume()
        } else {
            finishContinuation.resume(throwing: SystemAudioPlaybackError.playbackFailed(status))
        }
    }
}

private enum TestModeAudioPlaybackError: LocalizedError {
    case sampleFileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sampleFileNotFound(let path):
            return "テストモード用サンプル音声が見つかりません: \(path)"
        }
    }
}
