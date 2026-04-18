import Foundation

/// テストモード用スクリプト生成サービス。
/// 外部CLIを呼ばず、即座にダミースクリプトを返す。
actor TestModeScriptGenerationService: ScriptGenerationService {
    func generateOpening(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        RadioScript(segmentType: "opening", dialogues: [], summaryBullets: [], track: tracks.first)
    }

    func generateTransition(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        settings: AppSettings,
        continuityNote: String?
    ) async throws -> RadioScript {
        RadioScript(segmentType: "transition", dialogues: [], summaryBullets: [], track: nextTrack)
    }

    func generateClosing(tracks: [TrackInfo], settings: AppSettings) async throws -> RadioScript {
        RadioScript(segmentType: "closing", dialogues: [], summaryBullets: [], track: tracks.last)
    }
}
