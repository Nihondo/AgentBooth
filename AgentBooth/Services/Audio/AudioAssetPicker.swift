import Foundation
import UniformTypeIdentifiers

/// BGM / ジングルの用途。
enum AudioCueRole: Sendable {
    case bed
    case openingJingle
    case closingJingle
}

/// BGM / ジングル設定から実際に再生する音声ファイルを選ぶ。
struct AudioAssetPicker: Sendable {
    /// 音源指定から再生可能な音声ファイル URL を返す。
    func pickAudioFile(from source: AudioAssetSource, role: AudioCueRole) -> URL? {
        let trimmedPath = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmedPath)
        switch source.kind {
        case .file:
            return isAudioFile(url) ? url : nil
        case .directory:
            return pickAudioFile(in: url)
        }
    }

    private func pickAudioFile(in directoryURL: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let audioFiles = candidates
            .filter { isAudioFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return audioFiles.randomElement()
    }

    private func isAudioFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }

        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .audio)
    }
}
