import Foundation

/// グローバル辞書（`AppSettings.globalPronunciationEntries`、全番組共通）と
/// プロフィール辞書（`DirectionSettings.pronunciationEntries`、この番組固有）をマージし、
/// TTS プロンプトに渡す実効辞書を作る純関数群。
///
/// マージ規則:
/// 1. `isEnabled == false`、または `source` / `reading` が空（trim後）のエントリは除外する。
/// 2. 同一スコープ内でキーが重複する場合は後勝ち。
/// 3. グローバルとプロフィールでキーが衝突する場合はプロフィール側が優先されるが、
///    出力位置はグローバル側の位置を維持する（差し替え）。
/// 4. プロフィール固有のエントリ（グローバルと衝突しないもの）はグローバル分の後ろに追加する。
enum PronunciationDictionaryResolver {
    /// `AppSettings` からグローバル辞書とプロフィール辞書を取り出してマージする。
    static func resolve(settings: AppSettings) -> [PronunciationEntry] {
        merge(global: settings.globalPronunciationEntries, profile: settings.directionSettings.pronunciationEntries)
    }

    static func merge(global: [PronunciationEntry], profile: [PronunciationEntry]) -> [PronunciationEntry] {
        let normalizedGlobal = normalize(global)
        let normalizedProfile = normalize(profile)

        let profileByKey = Dictionary(normalizedProfile.map { (normalizedSource($0.source), $0) }, uniquingKeysWith: { _, last in last })

        var mergedKeys = Set<String>()
        var result: [PronunciationEntry] = []

        for entry in normalizedGlobal {
            let key = normalizedSource(entry.source)
            guard !mergedKeys.contains(key) else { continue }
            mergedKeys.insert(key)
            result.append(profileByKey[key] ?? entry)
        }

        for entry in normalizedProfile {
            let key = normalizedSource(entry.source)
            guard !mergedKeys.contains(key) else { continue }
            mergedKeys.insert(key)
            result.append(entry)
        }

        return result
    }

    /// 発音辞書のキー正規化。前後空白を除去し、Unicode 正規化形式（NFC）を揃える。
    static func normalizedSource(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// プロフィール側がグローバル側を上書きしている `source`（正規化済みキー）の集合。設定 UI での表示用。
    static func overriddenSources(global: [PronunciationEntry], profile: [PronunciationEntry]) -> Set<String> {
        let globalKeys = Set(normalize(global).map { normalizedSource($0.source) })
        let profileKeys = Set(normalize(profile).map { normalizedSource($0.source) })
        return globalKeys.intersection(profileKeys)
    }

    /// 無効・空エントリを除外し、同一スコープ内の重複は後勝ちで解決する。
    private static func normalize(_ entries: [PronunciationEntry]) -> [PronunciationEntry] {
        var order: [String] = []
        var byKey: [String: PronunciationEntry] = [:]

        for entry in entries {
            guard entry.isEnabled else { continue }
            let trimmedSource = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedReading = entry.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty, !trimmedReading.isEmpty else { continue }

            let key = normalizedSource(entry.source)
            if byKey[key] == nil {
                order.append(key)
            }
            byKey[key] = entry
        }

        return order.compactMap { byKey[$0] }
    }
}
