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
