import XCTest
@testable import AgentBooth

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testSaveAndLoadSettingsRoundTrip() throws {
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)
        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)

        var settings = AppSettings()
        settings.geminiAPIKey = "secret-key"
        settings.scriptCLIKind = .codex
        settings.defaultOverlapMode = .introOver
        settings.radioShowSettings.showName = "Night Radio"
        settings.volumeSettings.speakAfterSeconds = 12
        settings.volumeSettings.fadeEarlySeconds = 9

        try store.saveSettings(settings)

        let reloadedStore = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(reloadedStore.currentSettings.geminiAPIKey, "secret-key")
        XCTAssertEqual(reloadedStore.currentSettings.scriptCLIKind, .codex)
        XCTAssertEqual(reloadedStore.currentSettings.defaultOverlapMode, .introOver)
        XCTAssertEqual(reloadedStore.currentSettings.radioShowSettings.showName, "Night Radio")
        XCTAssertEqual(reloadedStore.currentSettings.volumeSettings.speakAfterSeconds, 12)
        XCTAssertEqual(reloadedStore.currentSettings.volumeSettings.fadeEarlySeconds, 9)
    }

    func testCustomCLISettingsRoundTrip() throws {
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)
        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)

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
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)

        // 旧バージョンの JSON (customCLI フィールドなし) を模倣
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

    func testLoadLegacyMusicBedFallsBackToFullRadio() throws {
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)

        let encodedSettings = try JSONEncoder().encode(AppSettings())
        let legacyData = try XCTUnwrap(
            String(data: encodedSettings, encoding: .utf8)?
                .replacingOccurrences(of: "\"defaultOverlapMode\":\"full_radio\"", with: "\"defaultOverlapMode\":\"music_bed\"")
                .data(using: .utf8)
        )
        defaults.set(legacyData, forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.defaultOverlapMode, .fullRadio)
    }
}
