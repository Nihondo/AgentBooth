import Foundation
import Combine

private struct TTSKeychainBundle: Codable {
    var keysByID: [String: String]
}

enum AppSettingsStoreError: LocalizedError, Equatable {
    case profileNotFound
    case cannotDeleteLastProfile

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return String(localized: "プロフィールが見つかりません。")
        case .cannotDeleteLastProfile:
            return String(localized: "最後のプロフィールは削除できません。")
        }
    }
}

/// Stores persisted settings in UserDefaults and Keychain.
@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var currentSettings: AppSettings
    @Published private(set) var showProfiles: [ShowProfile]

    private let userDefaults: UserDefaults
    private let keychainStore: KeychainStore
    private let showProfileStore: ShowProfileStore
    private let settingsKey = "app_settings"
    private let apiKeyAccountName = "gemini_api_key"

    init(
        userDefaults: UserDefaults = .standard,
        keychainStore: KeychainStore = KeychainStore(serviceName: "com.dmng.AgentBooth"),
        showProfileStore: ShowProfileStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.keychainStore = keychainStore
        self.showProfileStore = showProfileStore ?? ShowProfileStore(userDefaults: userDefaults)
        self.currentSettings = .init()
        self.showProfiles = []
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

        var loadedProfiles = showProfileStore.loadProfiles() ?? []
        if loadedProfiles.isEmpty || loadedSettings.activeProfileId == nil {
            let profileID = loadedSettings.activeProfileId ?? UUID()
            let migratedProfile = ShowProfile(
                id: profileID,
                name: String(localized: "デフォルト"),
                settings: loadedSettings
            )
            loadedSettings.activeProfileId = profileID
            loadedProfiles = [migratedProfile]
            try? showProfileStore.saveProfiles(loadedProfiles)
        }

        let activeProfile = resolveActiveProfile(settings: &loadedSettings, profiles: loadedProfiles)
        showProfiles = loadedProfiles
        currentSettings = loadedSettings.applyingProfile(activeProfile)
        try? persistSettingsSnapshot(currentSettings)
    }

    func saveSettings(_ settings: AppSettings) throws {
        let profileID = settings.activeProfileId ?? currentSettings.activeProfileId ?? showProfiles.first?.id ?? UUID()
        var nextSettings = settings
        nextSettings.activeProfileId = profileID
        var nextProfiles = showProfiles

        if let index = nextProfiles.firstIndex(where: { $0.id == profileID }) {
            let profileName = nextProfiles[index].name
            nextProfiles[index] = ShowProfile(id: profileID, name: profileName, settings: nextSettings)
        } else {
            nextProfiles.append(
                ShowProfile(id: profileID, name: String(localized: "デフォルト"), settings: nextSettings)
            )
        }

        try persist(settings: nextSettings, profiles: nextProfiles)
    }

    func updateSettings(_ mutateSettings: (inout AppSettings) -> Void) throws {
        var nextSettings = currentSettings
        mutateSettings(&nextSettings)
        try saveSettings(nextSettings)
    }

    func selectProfile(_ profileID: UUID) throws {
        guard let profile = showProfiles.first(where: { $0.id == profileID }) else {
            throw AppSettingsStoreError.profileNotFound
        }

        let nextSettings = currentSettings.applyingProfile(profile)
        try persist(settings: nextSettings, profiles: showProfiles)
    }

    @discardableResult
    func createProfile(named name: String) throws -> ShowProfile {
        let normalizedName = normalizedProfileName(name, fallback: String(localized: "新規プロフィール"))
        let profile = ShowProfile(name: normalizedName, settings: currentSettings)
        var nextProfiles = showProfiles
        nextProfiles.append(profile)
        let nextSettings = currentSettings.applyingProfile(profile)
        try persist(settings: nextSettings, profiles: nextProfiles)
        return profile
    }

    @discardableResult
    func duplicateProfile(id profileID: UUID) throws -> ShowProfile {
        guard let sourceProfile = showProfiles.first(where: { $0.id == profileID }) else {
            throw AppSettingsStoreError.profileNotFound
        }

        var duplicatedProfile = sourceProfile
        duplicatedProfile.id = UUID()
        duplicatedProfile.name = normalizedProfileName(
            String(format: String(localized: "%@ のコピー"), sourceProfile.name),
            fallback: String(localized: "プロフィールのコピー")
        )

        var nextProfiles = showProfiles
        nextProfiles.append(duplicatedProfile)
        let nextSettings = currentSettings.applyingProfile(duplicatedProfile)
        try persist(settings: nextSettings, profiles: nextProfiles)
        return duplicatedProfile
    }

    func renameProfile(id profileID: UUID, name: String) throws {
        guard let index = showProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppSettingsStoreError.profileNotFound
        }

        var nextProfiles = showProfiles
        nextProfiles[index].name = normalizedProfileName(name, fallback: nextProfiles[index].name)
        try persist(settings: currentSettings, profiles: nextProfiles)
    }

    func deleteProfile(id profileID: UUID) throws {
        guard showProfiles.count > 1 else {
            throw AppSettingsStoreError.cannotDeleteLastProfile
        }
        guard showProfiles.contains(where: { $0.id == profileID }) else {
            throw AppSettingsStoreError.profileNotFound
        }

        let nextProfiles = showProfiles.filter { $0.id != profileID }
        let nextProfile = nextProfiles.first!
        let activeProfileID = currentSettings.activeProfileId
        let nextSettings = activeProfileID == profileID
            ? currentSettings.applyingProfile(nextProfile)
            : currentSettings
        try persist(settings: nextSettings, profiles: nextProfiles)
    }

    private func resolveActiveProfile(settings: inout AppSettings, profiles: [ShowProfile]) -> ShowProfile {
        if let activeProfileId = settings.activeProfileId,
           let activeProfile = profiles.first(where: { $0.id == activeProfileId }) {
            return activeProfile
        }

        let fallbackProfile = profiles[0]
        settings.activeProfileId = fallbackProfile.id
        return fallbackProfile
    }

    private func persist(settings: AppSettings, profiles: [ShowProfile]) throws {
        var nextSettings = settings
        let activeProfile = resolveActiveProfile(settings: &nextSettings, profiles: profiles)
        let composedSettings = nextSettings.applyingProfile(activeProfile)
        try showProfileStore.saveProfiles(profiles)
        try persistSettingsSnapshot(composedSettings)
        try persistKeychainBundle(settings.ttsCredentialSets)
        showProfiles = profiles
        currentSettings = composedSettings
    }

    private func persistSettingsSnapshot(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings.strippingSecrets())
        userDefaults.set(data, forKey: settingsKey)
    }

    private func persistKeychainBundle(_ credentialSets: [TTSCredentialSet]) throws {
        let keychainBundle = TTSKeychainBundle(
            keysByID: Dictionary(
                uniqueKeysWithValues: credentialSets.map { credentialSet in
                    (credentialSet.id.uuidString, credentialSet.apiKey)
                }
            )
        )
        let bundleData = try JSONEncoder().encode(keychainBundle)
        let bundleText = String(decoding: bundleData, as: UTF8.self)
        try keychainStore.writeSecret(bundleText, accountName: apiKeyAccountName)
    }

    private func normalizedProfileName(_ name: String, fallback: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? fallback : trimmedName
    }
}
