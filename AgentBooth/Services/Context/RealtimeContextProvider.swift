import Foundation

/// 台本生成時に使う現在時刻まわりの番組コンテキスト。
struct RealtimeContext: Equatable, Sendable {
    var hour: Int
    var weekday: String
    var season: String
    var monthName: String
    var locationName: String?
}

/// ローカル日時と番組設定から、ナマ放送感を出すための文脈を生成する。
enum RealtimeContextProvider {
    /// 指定日時の時刻・曜日・季節・月名と、設定済みの地域名を返す。
    static func makeContext(
        date: Date = Date(),
        calendar: Calendar = .current,
        settings: RadioShowSettings
    ) -> RealtimeContext {
        let hour = calendar.component(.hour, from: date)
        let month = calendar.component(.month, from: date)
        let weekdayIndex = calendar.component(.weekday, from: date)

        return RealtimeContext(
            hour: hour,
            weekday: weekdayName(for: weekdayIndex),
            season: seasonName(for: month),
            monthName: "\(month)月",
            locationName: trimmedLocationName(settings.locationName)
        )
    }

    private static func weekdayName(for weekdayIndex: Int) -> String {
        switch weekdayIndex {
        case 1:
            return "日曜日"
        case 2:
            return "月曜日"
        case 3:
            return "火曜日"
        case 4:
            return "水曜日"
        case 5:
            return "木曜日"
        case 6:
            return "金曜日"
        case 7:
            return "土曜日"
        default:
            return ""
        }
    }

    private static func seasonName(for month: Int) -> String {
        switch month {
        case 3...5:
            return "春"
        case 6...8:
            return "夏"
        case 9...11:
            return "秋"
        default:
            return "冬"
        }
    }

    private static func trimmedLocationName(_ locationName: String?) -> String? {
        guard let locationName else { return nil }
        let trimmedValue = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
