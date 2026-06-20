import XCTest
@testable import AgentBooth

final class RealtimeContextProviderTests: XCTestCase {
    func testMakeContextUsesLocalCalendarAndTrimsLocationName() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 5, day: 11, hour: 7))
        )
        var settings = RadioShowSettings()
        settings.locationName = " 東京 "

        let context = RealtimeContextProvider.makeContext(
            date: date,
            calendar: calendar,
            settings: settings
        )

        XCTAssertEqual(context.hour, 7)
        XCTAssertEqual(context.weekday, "月曜日")
        XCTAssertEqual(context.season, "春")
        XCTAssertEqual(context.monthName, "5月")
        XCTAssertEqual(context.locationName, "東京")
    }

    func testOpeningPromptIncludesRealtimeContextAndWeatherInstructionWhenLocationIsSet() {
        var settings = AppSettings()
        settings.radioShowSettings.showName = "AgentBooth Radio"
        settings.radioShowSettings.frequency = "77.5 FM"
        settings.radioShowSettings.locationName = "東京"
        let track = TrackInfo(name: "Song", artist: "Artist", album: "Album")

        let prompt = PromptBuilder.buildOpeningPrompt(tracks: [track], settings: settings)

        XCTAssertTrue(prompt.contains("- 番組名: AgentBooth Radio"))
        XCTAssertTrue(prompt.contains("- 周波数: 77.5 FM"))
        XCTAssertTrue(prompt.contains("- 現在時刻:"))
        XCTAssertTrue(prompt.contains("- 曜日:"))
        XCTAssertTrue(prompt.contains("- 季節:"))
        XCTAssertTrue(prompt.contains("- 現在地: 東京"))
        XCTAssertTrue(prompt.contains("不確実な場合は省略する"))
    }

    func testOpeningPromptPrioritizesScriptDirectionTimeBandOverRealtimeContext() {
        var settings = AppSettings()
        settings.directionSettings.scriptDirection = "夜の番組として、落ち着いた挨拶から始める"
        let track = TrackInfo(name: "Song", artist: "Artist", album: "Album")

        let prompt = PromptBuilder.buildOpeningPrompt(tracks: [track], settings: settings)

        XCTAssertTrue(prompt.contains("【台本ディレクション】"))
        XCTAssertTrue(prompt.contains("夜の番組として、落ち着いた挨拶から始める"))
        XCTAssertTrue(prompt.contains("【台本ディレクションの優先順位】"))
        XCTAssertTrue(prompt.contains("台本ディレクションは【番組情報】より優先する"))
        XCTAssertTrue(prompt.contains("番組上の時間帯として扱う"))
        XCTAssertTrue(prompt.contains("現在時刻と矛盾する時間帯表現は避ける"))
        XCTAssertTrue(prompt.contains("- 現在時刻:"))
    }

    func testOpeningPromptOmitsPriorityBlockWhenScriptDirectionIsEmpty() {
        let settings = AppSettings()
        let track = TrackInfo(name: "Song", artist: "Artist", album: "Album")

        let prompt = PromptBuilder.buildOpeningPrompt(tracks: [track], settings: settings)

        XCTAssertFalse(prompt.contains("【台本ディレクションの優先順位】"))
        XCTAssertTrue(prompt.contains("- 現在時刻:"))
    }
}
