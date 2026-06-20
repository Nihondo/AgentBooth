import Foundation

/// Application Support に事前生成済み台本を1セッションだけ保存するストア。
actor PreGeneratedScriptStore: PreGeneratedScriptStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = PreGeneratedScriptStore.makeDefaultFileURL(fileManager: fileManager)
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
        try? fileManager.removeItem(at: fileURL)
    }

    private static func makeDefaultFileURL(fileManager: FileManager) -> URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportURL
            .appendingPathComponent("AgentBooth", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("pregenerated_session.json")
    }
}
