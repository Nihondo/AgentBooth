import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case noDisplayAvailable
    case capturePermissionDenied(String)
    case writerSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return String(localized: "キャプチャに使用できるディスプレイが見つかりません。")
        case .capturePermissionDenied(let detail):
            return String(format: String(localized: "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で AgentBooth を許可してください。(%@)"), detail)
        case .writerSetupFailed(let detail):
            return String(format: String(localized: "録音ファイルの準備に失敗しました: %@"), detail)
        }
    }
}

// MARK: - SCStreamOutput bridge

/// SCStreamOutput は NSObjectProtocol を必要とするため、actor から直接準拠できない。
/// このクラスが SCStreamOutput を実装し、受け取ったバッファを actor に転送する。
private final class AudioStreamOutputHandler: NSObject, SCStreamOutput {
    private let onAudioBuffer: (CMSampleBuffer) -> Void

    init(onAudioBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onAudioBuffer = onAudioBuffer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        onAudioBuffer(sampleBuffer)
    }
}

// MARK: - SystemAudioCaptureService

/// ScreenCaptureKit でシステム音声をキャプチャし、非圧縮 WAV ファイルに書き出す。
/// ノイズ切り分けのため一時的に非圧縮ルートを使用中。M4A ルートは makeM4AAssetWriter で保持。
actor SystemAudioCaptureService: ShowRecordingServiceProtocol {
    private var stream: SCStream?
    private var streamOutputHandler: AudioStreamOutputHandler?
    private var assetWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isCapturing = false
    /// エンコーダーが一時的にビジーのときに溜めるバッファキュー
    private var pendingBuffers: [CMSampleBuffer] = []
    /// キューの上限（48kHz/1024サンプルフレームで約420ms分）
    private static let maxPendingBuffers = 20

    func startRecording(outputURL: URL) async throws {
        guard !isCapturing else { return }

        // 既存ファイルがあれば削除
        try? FileManager.default.removeItem(at: outputURL)

        // 出力ディレクトリを作成
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // AVAssetWriter セットアップ（非圧縮WAVルート）
        let writer = try makeWAVAssetWriter(outputURL: outputURL)
        assetWriter = writer
        sessionStarted = false

        // SCShareableContent でメインディスプレイを取得
        let availableContent: SCShareableContent
        do {
            availableContent = try await SCShareableContent.current
        } catch {
            throw SystemAudioCaptureError.capturePermissionDenied(error.localizedDescription)
        }

        guard let display = availableContent.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        // 全アプリの音声をキャプチャ（除外なし）
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        // ビデオは SCStream が必須とするため最小サイズに設定し、映像フレームは無視する
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // SCStreamOutput の bridge オブジェクトを作成
        let handler = AudioStreamOutputHandler { [weak self] sampleBuffer in
            Task { [weak self] in
                await self?.appendAudioBuffer(sampleBuffer)
            }
        }
        streamOutputHandler = handler

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: .global(qos: .utility))

        writer.startWriting()

        do {
            try await newStream.startCapture()
        } catch {
            throw SystemAudioCaptureError.capturePermissionDenied(error.localizedDescription)
        }

        stream = newStream
        isCapturing = true
    }

    func stopRecording() async throws {
        guard isCapturing, let currentStream = stream else { return }
        isCapturing = false

        try? await currentStream.stopCapture()
        stream = nil
        streamOutputHandler = nil

        guard let writer = assetWriter, let input = audioWriterInput else { return }

        // 停止時にキュー残りをフラッシュ
        while !pendingBuffers.isEmpty, input.isReadyForMoreMediaData {
            input.append(pendingBuffers.removeFirst())
        }
        pendingBuffers.removeAll()

        input.markAsFinished()
        await writer.finishWriting()
        assetWriter = nil
        audioWriterInput = nil
        sessionStarted = false
    }

    // MARK: - Private

    /// 非圧縮 WAV（24bit/48kHz/ステレオ）で書き出す。ノイズ切り分け用。
    private func makeWAVAssetWriter(outputURL: URL) throws -> AVAssetWriter {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        } catch {
            throw SystemAudioCaptureError.writerSetupFailed(error.localizedDescription)
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SystemAudioCaptureError.writerSetupFailed(String(localized: "AVAssetWriterInput の追加に失敗しました。"))
        }
        writer.add(input)
        audioWriterInput = input

        return writer
    }

    /// AAC 192kbps で M4A に書き出す（ノイズ切り分け後に戻す用途で保持）。
    private func makeM4AAssetWriter(outputURL: URL) throws -> AVAssetWriter {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw SystemAudioCaptureError.writerSetupFailed(error.localizedDescription)
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SystemAudioCaptureError.writerSetupFailed(String(localized: "AVAssetWriterInput の追加に失敗しました。"))
        }
        writer.add(input)
        audioWriterInput = input

        return writer
    }

    private func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing,
              let writer = assetWriter,
              let input = audioWriterInput,
              writer.status == .writing else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }

        pendingBuffers.append(sampleBuffer)

        // 極端な遅延を防ぐため上限を超えた古いバッファは捨てる
        if pendingBuffers.count > Self.maxPendingBuffers {
            pendingBuffers.removeFirst(pendingBuffers.count - Self.maxPendingBuffers)
        }

        while !pendingBuffers.isEmpty, input.isReadyForMoreMediaData {
            input.append(pendingBuffers.removeFirst())
        }
    }
}
