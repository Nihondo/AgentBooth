import Foundation

/// 番組プロフィール配列を UserDefaults に保存する小さなストア。
final class ShowProfileStore {
    private let userDefaults: UserDefaults
    private let profilesKey = "show_profiles"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// 保存済みプロフィールを読み込む。未保存または破損時は nil を返す。
    func loadProfiles() -> [ShowProfile]? {
        guard let data = userDefaults.data(forKey: profilesKey) else { return nil }
        return try? JSONDecoder().decode([ShowProfile].self, from: data)
    }

    /// プロフィール配列を JSON として保存する。
    func saveProfiles(_ profiles: [ShowProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        userDefaults.set(data, forKey: profilesKey)
    }
}
