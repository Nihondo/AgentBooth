import Foundation

/// Gemini TTS モデルが要求するリクエストスキーマ。
///
/// `gemini-2.5-*-preview-tts` / `gemini-3.1-flash-tts-preview` までは、1つの text part に
/// `Direction:` ブロックや `Male:` / `Female:` ラベルを書き込んだ単一プロンプトを送る（`.legacyPrompt`）。
/// `gemini-3.8-flash-tts` 以降は入力テキストを逐語トランスクリプトとして扱うため、
/// スタイル・話者指定は part ごとの `speech_metadata` に分離する必要がある（`.speechMetadata`）。
/// 詳細は `docs/gemini-38-tts-migration.md` を参照。
enum GeminiTTSRequestSchema: Equatable, Sendable {
    case legacyPrompt
    case speechMetadata

    /// モデル名から要求スキーマを判定する。
    /// `gemini-<major>.<minor>-...` の形式でメジャー/マイナーを取り出し、3.8 以降なら `.speechMetadata`。
    /// 将来の `gemini-4-...-tts`（マイナーなし = メジャーのみ）も新スキーマ側に倒す。
    /// パターンに一致しない名前（テスト用のダミーモデル名など）は `.legacyPrompt` を返す。
    static func forModel(_ modelName: String) -> GeminiTTSRequestSchema {
        guard let (major, minor) = parseVersion(from: modelName) else {
            return .legacyPrompt
        }
        if major > 3 || (major == 3 && minor >= 8) {
            return .speechMetadata
        }
        return .legacyPrompt
    }

    private static func parseVersion(from modelName: String) -> (major: Int, minor: Int)? {
        guard let regex = try? NSRegularExpression(pattern: "^gemini-(\\d+)(?:\\.(\\d+))?-") else {
            return nil
        }
        let range = NSRange(modelName.startIndex..., in: modelName)
        guard let match = regex.firstMatch(in: modelName, range: range),
              let majorRange = Range(match.range(at: 1), in: modelName),
              let major = Int(modelName[majorRange]) else {
            return nil
        }
        guard let minorRange = Range(match.range(at: 2), in: modelName), !modelName[minorRange].isEmpty else {
            return (major, 0)
        }
        let minor = Int(modelName[minorRange]) ?? 0
        return (major, minor)
    }
}
