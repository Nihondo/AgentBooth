import AVFoundation
import Foundation

/// テストモード用 TTS サービス。
/// Gemini API を呼ばず、Application Support/AgentBooth/sample/sampletalk.m4a の
/// 実際の長さに対応したダミー WAV データを返す。
/// 音声の実再生は TestModeAudioPlaybackService 側がパスを直接使う。
actor TestModeTTSService: TTSService {
    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        let url = Self.sampleFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TestModeTTSError.sampleFileNotFound(url.path)
        }
        let durationSeconds = await fetchAudioDuration(url: url)
        // RadioOrchestrator.wavDurationSeconds() が正しい秒数を返せるよう、
        // PCM 24kHz 16bit 換算のバイト数を持つダミー WAV データを生成する。
        let pcmBytes = max(0, Int(durationSeconds * 24_000 * 2))
        let wavData = Data(count: 44 + pcmBytes)
        return TTSResult(wavData: wavData, modelUsed: "test_mode", didUseFallback: false)
    }

    static var sampleFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBooth/sample/sampletalk.m4a")
    }

    private func fetchAudioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds
        } catch {
            return 52.0
        }
    }
}

private enum TestModeTTSError: LocalizedError {
    case sampleFileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sampleFileNotFound(let path):
            return "テストモード用サンプル音声が見つかりません: \(path)"
        }
    }
}
