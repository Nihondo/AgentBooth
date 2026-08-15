import XCTest
@testable import AgentBooth

final class PronunciationDictionaryResolverTests: XCTestCase {
    func testMergeReturnsGlobalOnlyWhenProfileIsEmpty() {
        let global = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]
        let merged = PronunciationDictionaryResolver.merge(global: global, profile: [])
        XCTAssertEqual(merged.map(\.source), ["女神転生"])
        XCTAssertEqual(merged.map(\.reading), ["メガミテンセイ"])
    }

    func testMergeReturnsProfileOnlyWhenGlobalIsEmpty() {
        let profile = [PronunciationEntry(source: "Ys", reading: "イース")]
        let merged = PronunciationDictionaryResolver.merge(global: [], profile: profile)
        XCTAssertEqual(merged.map(\.source), ["Ys"])
    }

    func testMergeCombinesNonConflictingEntriesFromBothScopes() {
        let global = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]
        let profile = [PronunciationEntry(source: "Ys", reading: "イース")]
        let merged = PronunciationDictionaryResolver.merge(global: global, profile: profile)
        XCTAssertEqual(merged.map(\.source), ["女神転生", "Ys"])
    }

    /// 衝突時はプロフィール側が優先されるが、出力位置はグローバル側の位置を維持する（差し替え）。
    func testMergeProfilePrevailsOnConflictButKeepsGlobalPosition() {
        let global = [
            PronunciationEntry(source: "女神転生", reading: "めがみてんせい"),
            PronunciationEntry(source: "Ys", reading: "ワイエス")
        ]
        let profile = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]

        let merged = PronunciationDictionaryResolver.merge(global: global, profile: profile)

        XCTAssertEqual(merged.map(\.source), ["女神転生", "Ys"])
        XCTAssertEqual(merged[0].reading, "メガミテンセイ", "プロフィール側の読みが優先される")
        XCTAssertEqual(merged[1].reading, "ワイエス")
    }

    /// 同一スコープ内でキーが重複する場合は後勝ち。
    func testMergeResolvesDuplicateWithinSameScopeByLastWins() {
        let global = [
            PronunciationEntry(source: "MOTHER", reading: "マザーワン"),
            PronunciationEntry(source: "MOTHER", reading: "マザー")
        ]
        let merged = PronunciationDictionaryResolver.merge(global: global, profile: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].reading, "マザー")
    }

    func testMergeExcludesDisabledEntries() {
        let global = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ", isEnabled: false)]
        let merged = PronunciationDictionaryResolver.merge(global: global, profile: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeExcludesEntriesWithEmptySourceOrReading() {
        let global = [
            PronunciationEntry(source: "", reading: "からのそうき"),
            PronunciationEntry(source: "からのよみ", reading: "")
        ]
        let merged = PronunciationDictionaryResolver.merge(global: global, profile: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeTrimsWhitespaceInKeyComparison() {
        let global = [PronunciationEntry(source: "  女神転生  ", reading: "めがみてんせい")]
        let profile = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]
        let merged = PronunciationDictionaryResolver.merge(global: global, profile: profile)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].reading, "メガミテンセイ")
    }

    func testOverriddenSourcesReturnsIntersectionOfKeys() {
        let global = [
            PronunciationEntry(source: "女神転生", reading: "めがみてんせい"),
            PronunciationEntry(source: "Ys", reading: "ワイエス")
        ]
        let profile = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]

        let overridden = PronunciationDictionaryResolver.overriddenSources(global: global, profile: profile)

        XCTAssertEqual(overridden, [PronunciationDictionaryResolver.normalizedSource("女神転生")])
    }

    func testResolveReadsBothScopesFromAppSettings() {
        var settings = AppSettings()
        settings.globalPronunciationEntries = [PronunciationEntry(source: "女神転生", reading: "メガミテンセイ")]
        settings.directionSettings.pronunciationEntries = [PronunciationEntry(source: "Ys", reading: "イース")]

        let resolved = PronunciationDictionaryResolver.resolve(settings: settings)

        XCTAssertEqual(Set(resolved.map(\.source)), ["女神転生", "Ys"])
    }
}
