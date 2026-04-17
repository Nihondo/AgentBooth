import Foundation
import Combine

private struct TTSKeychainBundle: Codable {
    var keysByID: [String: String]
}

/// Stores persisted settings in UserDefaults and Keychain.
@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var currentSettings: AppSettings

    private let userDefaults: UserDefaults
    private let keychainStore: KeychainStore
    private let settingsKey = "app_settings"
    private let apiKeyAccountName = "gemini_api_key"

    init(
        userDefaults: UserDefaults = .standard,
        keychainStore: KeychainStore = KeychainStore(serviceName: "com.dmng.AgentBooth")
    ) {
        self.userDefaults = userDefaults
        self.keychainStore = keychainStore
        self.currentSettings = .init()
        loadSettings()
    }

    func loadSettings() {
        var loadedSettings = AppSettings()

        if let data = userDefaults.data(forKey: settingsKey),
           let decodedSettings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loadedSettings = decodedSettings
        }

        if let storedSecret = try? keychainStore.readSecret(accountName: apiKeyAccountName),
           let bundleData = storedSecret.data(using: .utf8),
           let keychainBundle = try? JSONDecoder().decode(TTSKeychainBundle.self, from: bundleData) {
            loadedSettings.ttsCredentialSets = loadedSettings.ttsCredentialSets.map { credentialSet in
                var updatedSet = credentialSet
                updatedSet.apiKey = keychainBundle.keysByID[credentialSet.id.uuidString] ?? ""
                return updatedSet
            }
        }

        currentSettings = loadedSettings
    }

    func saveSettings(_ settings: AppSettings) throws {
        var persistedSettings = settings
        let keychainBundle = TTSKeychainBundle(
            keysByID: Dictionary(
                uniqueKeysWithValues: settings.ttsCredentialSets.map { credentialSet in
                    (credentialSet.id.uuidString, credentialSet.apiKey)
                }
            )
        )

        persistedSettings.geminiAPIKey = ""
        persistedSettings.ttsCredentialSets = settings.ttsCredentialSets.map { credentialSet in
            var persistedSet = credentialSet
            persistedSet.apiKey = ""
            return persistedSet
        }

        let data = try JSONEncoder().encode(persistedSettings)
        userDefaults.set(data, forKey: settingsKey)
        let bundleData = try JSONEncoder().encode(keychainBundle)
        let bundleText = String(decoding: bundleData, as: UTF8.self)
        try keychainStore.writeSecret(bundleText, accountName: apiKeyAccountName)
        currentSettings = settings
    }

    func updateSettings(_ mutateSettings: (inout AppSettings) -> Void) throws {
        var nextSettings = currentSettings
        mutateSettings(&nextSettings)
        try saveSettings(nextSettings)
    }
}
