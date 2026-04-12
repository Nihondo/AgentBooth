import Foundation
import Combine

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

        if let storedAPIKey = try? keychainStore.readSecret(accountName: apiKeyAccountName) {
            loadedSettings.geminiAPIKey = storedAPIKey
        }

        currentSettings = loadedSettings
    }

    func saveSettings(_ settings: AppSettings) throws {
        var persistedSettings = settings
        let apiKey = settings.geminiAPIKey
        persistedSettings.geminiAPIKey = ""

        let data = try JSONEncoder().encode(persistedSettings)
        userDefaults.set(data, forKey: settingsKey)
        try keychainStore.writeSecret(apiKey, accountName: apiKeyAccountName)
        currentSettings = settings
    }

    func updateSettings(_ mutateSettings: (inout AppSettings) -> Void) throws {
        var nextSettings = currentSettings
        mutateSettings(&nextSettings)
        try saveSettings(nextSettings)
    }
}
