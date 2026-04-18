import XCTest
@testable import AgentBooth

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testCredentialSetRoundTripAcrossReload() throws {
        let (defaults, keychainStore, store) = makeStore()

        var settings = AppSettings()
        settings.scriptCLIKind = .codex
        settings.defaultOverlapMode = .enabled
        settings.radioShowSettings.showName = "Night Radio"
        settings.ttsCredentialSets = [
            TTSCredentialSet(label: "main", apiKey: "secret-key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "", modelName: "model-2"),
            TTSCredentialSet(label: "third", apiKey: "secret-key-3", modelName: "model-3"),
        ]

        try store.saveSettings(settings)

        let reloadedStore = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(reloadedStore.currentSettings.scriptCLIKind, .codex)
        XCTAssertEqual(reloadedStore.currentSettings.defaultOverlapMode, .enabled)
        XCTAssertEqual(reloadedStore.currentSettings.radioShowSettings.showName, "Night Radio")
        XCTAssertEqual(
            reloadedStore.currentSettings.ttsCredentialSets.map(\.label),
            ["main", "backup", "third"]
        )
        XCTAssertEqual(
            reloadedStore.currentSettings.ttsCredentialSets.map(\.modelName),
            ["model-1", "model-2", "model-3"]
        )
        XCTAssertEqual(
            reloadedStore.currentSettings.ttsCredentialSets.map(\.apiKey),
            ["secret-key-1", "", "secret-key-3"]
        )
    }

    func testUserDefaultsDoesNotContainAPIKeys() throws {
        let (defaults, _, store) = makeStore()

        var settings = AppSettings()
        settings.ttsCredentialSets = [
            TTSCredentialSet(label: "main", apiKey: "secret-key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "secret-key-2", modelName: "model-2"),
        ]

        try store.saveSettings(settings)

        let data = try XCTUnwrap(defaults.data(forKey: "app_settings"))
        let decodedSettings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decodedSettings.ttsCredentialSets.map(\.apiKey), ["", ""])
    }

    func testSavePersistsKeychainBundle() throws {
        let (_, keychainStore, store) = makeStore()

        let firstSet = TTSCredentialSet(label: "main", apiKey: "secret-key-1", modelName: "model-1")
        let secondSet = TTSCredentialSet(label: "backup", apiKey: "", modelName: "model-2")

        var settings = AppSettings()
        settings.ttsCredentialSets = [firstSet, secondSet]

        try store.saveSettings(settings)

        let storedSecret = try keychainStore.readSecret(accountName: "gemini_api_key")
        let bundleData = try XCTUnwrap(storedSecret.data(using: .utf8))
        let bundle = try JSONDecoder().decode(KeychainBundleProbe.self, from: bundleData)
        XCTAssertEqual(
            bundle.keysByID,
            [
                firstSet.id.uuidString: "secret-key-1",
                secondSet.id.uuidString: "",
            ]
        )
    }

    func testLoadLeavesAPIKeysEmptyWhenKeychainBundleIsMissing() throws {
        let (defaults, keychainStore, _) = makeStore()

        var persistedSettings = AppSettings()
        persistedSettings.ttsCredentialSets = [
            TTSCredentialSet(label: "main", apiKey: "", modelName: "model-1"),
        ]
        defaults.set(try JSONEncoder().encode(persistedSettings), forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.ttsCredentialSets.map(\.apiKey), [""])
    }

    func testLoadLeavesAPIKeysEmptyWhenKeychainValueIsLegacyPlainText() throws {
        let (defaults, keychainStore, _) = makeStore()

        let persistedSet = TTSCredentialSet(label: "main", apiKey: "", modelName: "model-1")
        var persistedSettings = AppSettings()
        persistedSettings.ttsCredentialSets = [persistedSet]
        defaults.set(try JSONEncoder().encode(persistedSettings), forKey: "app_settings")
        try keychainStore.writeSecret("legacy-plain-text-key", accountName: "gemini_api_key")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.ttsCredentialSets.map(\.apiKey), [""])
    }

    func testCustomCLISettingsRoundTrip() throws {
        let (defaults, keychainStore, store) = makeStore()

        var settings = AppSettings()
        settings.scriptCLIKind = .custom
        settings.customCLIExecutable = "/opt/bin/mycli"
        settings.customCLIArguments = ["-p", "{prompt}"]
        settings.customCLIModelArguments = ["--model", "{model}"]

        try store.saveSettings(settings)

        let reloadedStore = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(reloadedStore.currentSettings.scriptCLIKind, .custom)
        XCTAssertEqual(reloadedStore.currentSettings.customCLIExecutable, "/opt/bin/mycli")
        XCTAssertEqual(reloadedStore.currentSettings.customCLIArguments, ["-p", "{prompt}"])
        XCTAssertEqual(reloadedStore.currentSettings.customCLIModelArguments, ["--model", "{model}"])
    }

    func testMissingCustomCLIFieldsFallBackToDefaults() throws {
        let (defaults, keychainStore, _) = makeStore()

        let legacySettings = AppSettings()
        var encoded = try JSONEncoder().encode(legacySettings)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "customCLIExecutable")
        json.removeValue(forKey: "customCLIArguments")
        json.removeValue(forKey: "customCLIModelArguments")
        encoded = try JSONSerialization.data(withJSONObject: json)
        defaults.set(encoded, forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.customCLIExecutable, "")
        XCTAssertEqual(store.currentSettings.customCLIArguments, [])
        XCTAssertEqual(store.currentSettings.customCLIModelArguments, [])
    }

    func testLoadLegacyMusicBedFallsBackToEnabled() throws {
        let (defaults, keychainStore, _) = makeStore()

        let encodedSettings = try JSONEncoder().encode(AppSettings())
        let legacyData = try XCTUnwrap(
            String(data: encodedSettings, encoding: .utf8)?
                .replacingOccurrences(of: "\"defaultOverlapMode\":\"enabled\"", with: "\"defaultOverlapMode\":\"music_bed\"")
                .data(using: .utf8)
        )
        defaults.set(legacyData, forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.defaultOverlapMode, .enabled)
    }

    func testLoadLegacySequentialFallsBackToDisabled() throws {
        let (defaults, keychainStore, _) = makeStore()

        let encodedSettings = try JSONEncoder().encode(AppSettings())
        let legacyData = try XCTUnwrap(
            String(data: encodedSettings, encoding: .utf8)?
                .replacingOccurrences(of: "\"defaultOverlapMode\":\"enabled\"", with: "\"defaultOverlapMode\":\"sequential\"")
                .data(using: .utf8)
        )
        defaults.set(legacyData, forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.defaultOverlapMode, .disabled)
    }

    private func makeStore() -> (UserDefaults, KeychainStore, AppSettingsStore) {
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)
        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        return (defaults, keychainStore, store)
    }
}

private struct KeychainBundleProbe: Decodable {
    let keysByID: [String: String]
}
