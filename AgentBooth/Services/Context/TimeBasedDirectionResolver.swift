import Foundation

/// 時間帯別プリセットを現在の番組設定へ反映する。
enum TimeBasedDirectionResolver {
    /// 指定日時の時間帯プリセットがあれば、sceneDirectionへ合成した設定を返す。
    static func makeSettings(
        settings: AppSettings,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> AppSettings {
        let timeBand = TimeBand.makeTimeBand(date: date, calendar: calendar)
        let preset = settings.directionSettings.timeBasedPresets[timeBand]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preset.isEmpty else {
            return settings
        }

        var updatedSettings = settings
        updatedSettings.directionSettings.sceneDirection = makeSceneDirection(
            baseDirection: settings.directionSettings.sceneDirection,
            preset: preset,
            timeBand: timeBand
        )
        return updatedSettings
    }

    private static func makeSceneDirection(
        baseDirection: String,
        preset: String,
        timeBand: TimeBand
    ) -> String {
        let trimmedBaseDirection = baseDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseDirection.isEmpty else {
            return preset
        }

        let timeBandHeader = String(
            format: String(localized: "時間帯別ディレクション（%@）:"),
            timeBand.displayName
        )
        return "\(trimmedBaseDirection)\n\n\(timeBandHeader)\n\(preset)"
    }
}
