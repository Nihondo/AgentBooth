import XCTest
@testable import AgentBooth

final class TimeBasedDirectionResolverTests: XCTestCase {
    func testTimeBandMapsHoursToExpectedBands() {
        XCTAssertEqual(TimeBand.makeTimeBand(hour: 4), .lateNight)
        XCTAssertEqual(TimeBand.makeTimeBand(hour: 5), .earlyMorning)
        XCTAssertEqual(TimeBand.makeTimeBand(hour: 8), .morning)
        XCTAssertEqual(TimeBand.makeTimeBand(hour: 12), .afternoon)
        XCTAssertEqual(TimeBand.makeTimeBand(hour: 17), .evening)
        XCTAssertEqual(TimeBand.makeTimeBand(hour: 20), .night)
    }

    func testMakeSettingsAppendsMatchingPresetToBaseDirection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 5, day: 11, hour: 21))
        )
        var settings = AppSettings()
        settings.directionSettings.sceneDirection = "共通ディレクション"
        settings.directionSettings.timeBasedPresets[.night] = "夜はしっとり話す"

        let resolvedSettings = TimeBasedDirectionResolver.makeSettings(
            settings: settings,
            date: date,
            calendar: calendar
        )

        XCTAssertTrue(resolvedSettings.directionSettings.sceneDirection.contains("共通ディレクション"))
        XCTAssertTrue(resolvedSettings.directionSettings.sceneDirection.contains("時間帯別ディレクション（夜）"))
        XCTAssertTrue(resolvedSettings.directionSettings.sceneDirection.contains("夜はしっとり話す"))
    }

    func testMakeSettingsLeavesDirectionUntouchedWhenPresetIsEmpty() {
        var settings = AppSettings()
        settings.directionSettings.sceneDirection = "共通ディレクション"
        settings.directionSettings.timeBasedPresets[.morning] = "   "

        let resolvedSettings = TimeBasedDirectionResolver.makeSettings(settings: settings)

        XCTAssertEqual(resolvedSettings.directionSettings.sceneDirection, "共通ディレクション")
    }
}
