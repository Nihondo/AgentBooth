import Foundation

/// テストモード用の BGM / ジングル再生サービス。
actor TestModeBedAudioPlaybackService: BedAudioPlaybackServiceProtocol {
    func estimateJingleDuration(settings: BGMSettings, placement: JinglePlacement) async -> Double { 0 }

    func playJingle(settings: BGMSettings, placement: JinglePlacement) async -> Double { 0 }

    func startBed(settings: BGMSettings) async {}

    func fadeOutAndStopBed(settings: BGMSettings) async {}

    func stopPlayback() async {}

    func pausePlayback() async {}

    func resumePlayback() async {}
}
