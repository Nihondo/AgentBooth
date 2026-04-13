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
