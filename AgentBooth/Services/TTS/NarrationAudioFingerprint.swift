import CryptoKit
import Foundation

/// TTS 合成結果（WAV）をディスクへキャッシュする際のキーを作る純関数群。
///
/// `GeminiTTSService.requestWAV` が API へ実際に送る内容（`TTSInputComposer.makeInput` の結果 +
/// 音声名 + モデル名）からキーを作ることで、台詞・発話指示・発音辞書・適用モード・音声名の
/// いずれかが変われば必ずキーも変わることを構造的に保証する。
///
/// プロセスをまたいで安定した値である必要があるため `Hasher` ではなく SHA-256 を使う
/// （`Hasher` は起動ごとにシードが変わるため、ディスクに残す永続キーには使えない）。
enum NarrationAudioFingerprint {
    static func make(dialogues: [DialogueLine], settings: AppSettings) -> String {
        let ttsInput = TTSInputComposer.makeInput(
            dialogues: dialogues,
            directionSettings: settings.directionSettings,
            pronunciationEntries: PronunciationDictionaryResolver.resolve(settings: settings)
        )
        let modelName = settings.activeTTSCredentialSets.first?.modelName ?? ""

        let components = [
            ttsInput,
            settings.voiceSettings.maleVoiceName,
            settings.voiceSettings.femaleVoiceName,
            modelName,
        ]
        // 区切り文字はハッシュ対象の値に含まれ得ない制御文字にして、
        // 連結時にフィールド境界が曖昧にならないようにする。
        let payload = components.joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
