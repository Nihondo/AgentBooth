import CryptoKit
import Foundation

/// TTS 合成結果（WAV）をディスクへキャッシュする際のキーを作る純関数群。
///
/// `GeminiTTSService.requestWAV` が API へ実際に送る内容（`TTSInputComposer.makePreviewText` の結果 +
/// 音声名 + モデル名）からキーを作ることで、台詞・発話指示・発音辞書・適用モード・音声名の
/// いずれかが変われば必ずキーも変わることを構造的に保証する。
///
/// プロセスをまたいで安定した値である必要があるため `Hasher` ではなく SHA-256 を使う
/// （`Hasher` は起動ごとにシードが変わるため、ディスクに残す永続キーには使えない）。
enum NarrationAudioFingerprint {
    static func make(dialogues: [DialogueLine], settings: AppSettings) -> String {
        let modelName = settings.activeTTSCredentialSets.first?.modelName ?? ""
        let schema = GeminiTTSRequestSchema.forModel(modelName)
        let ttsInput = TTSInputComposer.makePreviewText(
            dialogues: dialogues,
            directionSettings: settings.directionSettings,
            pronunciationEntries: PronunciationDictionaryResolver.resolve(settings: settings),
            schema: schema
        )

        var components = [
            ttsInput,
            settings.voiceSettings.maleVoiceName,
            settings.voiceSettings.femaleVoiceName,
            modelName,
        ]
        // speechMetadata スキーマ（Gemini 3.8 以降）はリクエストの組み立て方自体が legacy と異なる
        // （WAV レスポンスの扱いも変わる）ため、修正前に legacy 形式で誤生成されたキャッシュと
        // 衝突しないようキーへ明示的に含める。legacy 側のキーは変更前とバイト単位で同一に保ち、
        // 既存の 2.5 / 3.1 キャッシュを温存する。
        if schema == .speechMetadata {
            components.append("schema=speech_metadata")
            components.append("wav-format=2")
        }
        // 区切り文字はハッシュ対象の値に含まれ得ない制御文字にして、
        // 連結時にフィールド境界が曖昧にならないようにする。
        let payload = components.joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
