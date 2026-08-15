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

    func testMissingTimeBasedPresetsFallBackToEmptyDictionary() throws {
        let (defaults, keychainStore, _) = makeStore()

        let legacyDirectionSettings: [String: Any] = [
            "sceneDirection": "深夜帯、静かに話す",
        ]
        let legacySettings: [String: Any] = [
            "directionSettings": legacyDirectionSettings,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: legacySettings)
        defaults.set(encoded, forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.directionSettings.sceneDirection, "深夜帯、静かに話す")
        XCTAssertEqual(store.currentSettings.directionSettings.timeBasedPresets, [:])
    }

    func testPronunciationDictionariesRoundTripAcrossReload() throws {
        let (defaults, keychainStore, store) = makeStore()

        var settings = AppSettings()
        settings.globalPronunciationEntries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]
        settings.directionSettings.pronunciationEntries = [PronunciationEntry(source: "Ys", reading: "イース")]
        try store.saveSettings(settings)

        let reloadedStore = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(reloadedStore.currentSettings.globalPronunciationEntries.map(\.source), ["女神転生"])
        XCTAssertEqual(reloadedStore.currentSettings.directionSettings.pronunciationEntries.map(\.source), ["Ys"])
    }

    func testMissingPronunciationDictionaryFieldsFallBackToEmptyArrays() throws {
        let (defaults, keychainStore, _) = makeStore()

        let legacySettings = AppSettings()
        var encoded = try JSONEncoder().encode(legacySettings)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "globalPronunciationEntries")
        var directionSettingsJSON = try XCTUnwrap(json["directionSettings"] as? [String: Any])
        directionSettingsJSON.removeValue(forKey: "pronunciationEntries")
        json["directionSettings"] = directionSettingsJSON
        encoded = try JSONSerialization.data(withJSONObject: json)
        defaults.set(encoded, forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        XCTAssertEqual(store.currentSettings.globalPronunciationEntries, [])
        XCTAssertEqual(store.currentSettings.directionSettings.pronunciationEntries, [])
    }

    /// グローバル辞書はプロフィール切り替えの影響を受けず、プロフィール固有辞書だけが切り替わる。
    func testProfileSwitchIsolatesProfilePronunciationDictionaryButKeepsGlobal() throws {
        let (_, _, store) = makeStore()

        let nightProfileID = try XCTUnwrap(store.currentSettings.activeProfileId)
        var nightSettings = store.currentSettings
        nightSettings.globalPronunciationEntries = [PronunciationEntry(source: "共通語", reading: "きょうつうご")]
        nightSettings.directionSettings.pronunciationEntries = [PronunciationEntry(source: "深夜語", reading: "しんやご")]
        try store.saveSettings(nightSettings)

        let morningProfile = try store.createProfile(named: "朝の通勤")
        var morningSettings = store.currentSettings
        morningSettings.directionSettings.pronunciationEntries = [PronunciationEntry(source: "朝語", reading: "あさご")]
        try store.saveSettings(morningSettings)

        XCTAssertEqual(store.currentSettings.globalPronunciationEntries.map(\.source), ["共通語"])
        XCTAssertEqual(store.currentSettings.directionSettings.pronunciationEntries.map(\.source), ["朝語"])

        try store.selectProfile(nightProfileID)

        XCTAssertEqual(store.currentSettings.globalPronunciationEntries.map(\.source), ["共通語"], "グローバル辞書はプロフィール切替の影響を受けない")
        XCTAssertEqual(store.currentSettings.directionSettings.pronunciationEntries.map(\.source), ["深夜語"])

        _ = morningProfile
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

    func testLegacySettingsMigrateToDefaultProfile() throws {
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)

        var legacySettings = AppSettings()
        legacySettings.radioShowSettings.showName = "Night Radio"
        legacySettings.voiceSettings.maleVoiceName = "Charon"
        legacySettings.volumeSettings.talkVolume = 18
        defaults.set(try JSONEncoder().encode(legacySettings), forKey: "app_settings")

        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)

        XCTAssertEqual(store.showProfiles.count, 1)
        let profile = try XCTUnwrap(store.showProfiles.first)
        XCTAssertEqual(profile.name, "デフォルト")
        XCTAssertEqual(profile.radioShowSettings.showName, "Night Radio")
        XCTAssertEqual(profile.voiceSettings.maleVoiceName, "Charon")
        XCTAssertEqual(profile.volumeSettings.talkVolume, 18)
        XCTAssertEqual(store.currentSettings.activeProfileId, profile.id)
        XCTAssertEqual(store.currentSettings.radioShowSettings.showName, "Night Radio")
        XCTAssertNotNil(defaults.data(forKey: "show_profiles"))
    }

    func testSelectingProfileComposesProfileSettingsAndKeepsGlobalSettings() throws {
        let (_, _, store) = makeStore()

        let nightProfileID = try XCTUnwrap(store.currentSettings.activeProfileId)
        var nightSettings = store.currentSettings
        nightSettings.radioShowSettings.showName = "深夜帯"
        nightSettings.voiceSettings.maleVoiceName = "Charon"
        nightSettings.volumeSettings.talkVolume = 18
        try store.saveSettings(nightSettings)

        let morningProfile = try store.createProfile(named: "朝の通勤")
        var morningSettings = store.currentSettings
        morningSettings.radioShowSettings.showName = "朝の通勤"
        morningSettings.voiceSettings.maleVoiceName = "Puck"
        morningSettings.volumeSettings.talkVolume = 32
        morningSettings.defaultMusicService = .spotify
        try store.saveSettings(morningSettings)

        XCTAssertEqual(store.currentSettings.activeProfileId, morningProfile.id)
        try store.selectProfile(nightProfileID)

        XCTAssertEqual(store.currentSettings.radioShowSettings.showName, "深夜帯")
        XCTAssertEqual(store.currentSettings.voiceSettings.maleVoiceName, "Charon")
        XCTAssertEqual(store.currentSettings.volumeSettings.talkVolume, 18)
        XCTAssertEqual(store.currentSettings.defaultMusicService, .spotify)
    }

    func testProfileStorageDoesNotContainTTSAPIKeys() throws {
        let (defaults, _, store) = makeStore()

        var settings = store.currentSettings
        settings.ttsCredentialSets = [
            TTSCredentialSet(label: "main", apiKey: "secret-key-1", modelName: "model-1"),
        ]
        settings.radioShowSettings.showName = "Profile Radio"
        try store.saveSettings(settings)

        let settingsData = try XCTUnwrap(defaults.data(forKey: "app_settings"))
        let settingsText = String(decoding: settingsData, as: UTF8.self)
        XCTAssertFalse(settingsText.contains("secret-key-1"))

        let profilesData = try XCTUnwrap(defaults.data(forKey: "show_profiles"))
        let profilesText = String(decoding: profilesData, as: UTF8.self)
        XCTAssertFalse(profilesText.contains("secret-key-1"))

        let profiles = try JSONDecoder().decode([ShowProfile].self, from: profilesData)
        XCTAssertEqual(profiles.first?.radioShowSettings.showName, "Profile Radio")
    }

    func testDeletingLastProfileThrows() throws {
        let (_, _, store) = makeStore()

        let profileID = try XCTUnwrap(store.currentSettings.activeProfileId)
        XCTAssertThrowsError(try store.deleteProfile(id: profileID)) { error in
            XCTAssertEqual(error as? AppSettingsStoreError, .cannotDeleteLastProfile)
        }
    }

    func testDeletingActiveProfileSelectsFirstRemainingProfile() throws {
        let (_, _, store) = makeStore()

        let firstProfileID = try XCTUnwrap(store.currentSettings.activeProfileId)
        var firstSettings = store.currentSettings
        firstSettings.radioShowSettings.showName = "First"
        try store.saveSettings(firstSettings)

        let secondProfile = try store.createProfile(named: "Second")
        var secondSettings = store.currentSettings
        secondSettings.radioShowSettings.showName = "Second"
        try store.saveSettings(secondSettings)

        XCTAssertEqual(store.currentSettings.activeProfileId, secondProfile.id)
        try store.deleteProfile(id: secondProfile.id)

        XCTAssertEqual(store.showProfiles.map(\.id), [firstProfileID])
        XCTAssertEqual(store.currentSettings.activeProfileId, firstProfileID)
        XCTAssertEqual(store.currentSettings.radioShowSettings.showName, "First")
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
