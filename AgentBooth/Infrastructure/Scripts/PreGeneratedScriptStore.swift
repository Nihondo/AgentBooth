import Foundation

/// Application Support に事前生成済み台本を1セッションだけ保存するストア。
actor PreGeneratedScriptStore: PreGeneratedScriptStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.init(
            fileURL: PreGeneratedScriptStore.makeDefaultFileURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL
    }

    func save(_ session: PersistedScriptSession) async {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 台本保存の失敗は再生自体を止めない。次回は通常どおり再生成する。
        }
    }

    func load() async -> PersistedScriptSession? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(PersistedScriptSession.self, from: data)
        } catch {
            return nil
        }
    }

    func clear() async {
        // 台本セッションがアーカイブされて再利用候補から外れる以上、
        // 音声だけ残しても到達不能なゴミになるため、両方まとめて片付ける。
        await pruneNarrationAudio(keeping: [])

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let archiveURL = makeArchiveFileURL()
            try fileManager.moveItem(at: fileURL, to: archiveURL)
        } catch {
            // active キャッシュが残ると次回も再利用候補になるため、退避失敗時だけ削除へフォールバックする。
            try? fileManager.removeItem(at: fileURL)
        }
    }

    func loadNarrationAudio(fingerprint: String) async -> Data? {
        let audioURL = narrationAudioFileURL(fingerprint: fingerprint)
        guard fileManager.fileExists(atPath: audioURL.path) else {
            return nil
        }
        return try? Data(contentsOf: audioURL)
    }

    func saveNarrationAudio(_ wavData: Data, fingerprint: String) async {
        do {
            let directoryURL = narrationAudioDirectoryURL()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try wavData.write(to: narrationAudioFileURL(fingerprint: fingerprint), options: .atomic)
        } catch {
            // 音声キャッシュの保存失敗は再生自体を止めない。次回は通常どおり合成し直す。
        }
    }

    func pruneNarrationAudio(keeping fingerprints: Set<String>) async {
        let directoryURL = narrationAudioDirectoryURL()
        guard let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            guard fileURL.pathExtension == "wav" else { continue }
            let fingerprint = fileURL.deletingPathExtension().lastPathComponent
            guard !fingerprints.contains(fingerprint) else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func narrationAudioDirectoryURL() -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("audio", isDirectory: true)
    }

    private func narrationAudioFileURL(fingerprint: String) -> URL {
        narrationAudioDirectoryURL().appendingPathComponent("\(fingerprint).wav")
    }

    private func makeArchiveFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"

        let directoryURL = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        var candidateURL = directoryURL.appendingPathComponent(
            "\(baseName)_\(formatter.string(from: Date())).\(fileExtension)"
        )
        var suffix = 1
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL.appendingPathComponent(
                "\(baseName)_\(formatter.string(from: Date()))_\(suffix).\(fileExtension)"
            )
            suffix += 1
        }
        return candidateURL
    }

    private static func makeDefaultFileURL(fileManager: FileManager) -> URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportURL
            .appendingPathComponent("AgentBooth", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("pregenerated_session.json")
    }
}
