import AVFoundation
import Foundation

/// システムの音声プレイヤーでベッド BGM とジングルを再生するサービス。
actor SystemBedAudioPlaybackService: BedAudioPlaybackServiceProtocol {
    private let assetPicker: AudioAssetPicker
    private var bedPlayer: AVAudioPlayer?
    private var jinglePlayer: AVAudioPlayer?
    private var isPaused = false

    init(assetPicker: AudioAssetPicker = AudioAssetPicker()) {
        self.assetPicker = assetPicker
    }

    func estimateJingleDuration(settings: BGMSettings, placement: JinglePlacement) async -> Double {
        guard isJingleEnabled(settings: settings, placement: placement),
              let url = pickJingleURL(settings: settings, placement: placement),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            return 0
        }
        return max(0, player.duration)
    }

    func playJingle(settings: BGMSettings, placement: JinglePlacement) async -> Double {
        guard isJingleEnabled(settings: settings, placement: placement),
              let url = pickJingleURL(settings: settings, placement: placement),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            return 0
        }

        jinglePlayer?.stop()
        player.numberOfLoops = 0
        player.volume = clampedVolume(settings.jingleVolume)
        player.prepareToPlay()
        jinglePlayer = player
        isPaused = false
        guard player.play() else {
            jinglePlayer = nil
            return 0
        }

        let duration = max(0, player.duration)
        while jinglePlayer === player {
            if !isPaused && !player.isPlaying {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if jinglePlayer === player {
            jinglePlayer?.stop()
            jinglePlayer = nil
        }
        return duration
    }

    func startBed(settings: BGMSettings) async {
        guard settings.isBedEnabled,
              let url = assetPicker.pickAudioFile(from: settings.bedAudioSource, role: .bed),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }

        bedPlayer?.stop()
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        bedPlayer = player
        isPaused = false
        guard player.play() else {
            bedPlayer = nil
            return
        }

        await fade(player: player, targetVolume: clampedVolume(settings.bedVolume), durationSeconds: settings.bedFadeInDuration)
    }

    func fadeOutAndStopBed(settings: BGMSettings) async {
        guard let player = bedPlayer else {
            return
        }
        await fade(player: player, targetVolume: 0, durationSeconds: settings.bedFadeOutDuration)
        if bedPlayer === player {
            player.stop()
            bedPlayer = nil
        }
    }

    func stopPlayback() async {
        bedPlayer?.stop()
        jinglePlayer?.stop()
        bedPlayer = nil
        jinglePlayer = nil
        isPaused = false
    }

    func pausePlayback() async {
        bedPlayer?.pause()
        jinglePlayer?.pause()
        isPaused = true
    }

    func resumePlayback() async {
        if let bedPlayer, !bedPlayer.isPlaying {
            bedPlayer.play()
        }
        if let jinglePlayer, !jinglePlayer.isPlaying {
            jinglePlayer.play()
        }
        isPaused = false
    }

    private func fade(player: AVAudioPlayer, targetVolume: Float, durationSeconds: Double) async {
        guard durationSeconds > 0 else {
            player.volume = targetVolume
            return
        }

        let steps = 20
        let startVolume = player.volume
        let stepInterval = durationSeconds / Double(steps)
        let volumeDelta = targetVolume - startVolume

        for indexValue in 1...steps {
            guard bedPlayer === player || jinglePlayer === player else {
                return
            }
            player.volume = startVolume + volumeDelta * Float(indexValue) / Float(steps)
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, stepInterval) * 1_000_000_000))
        }
    }

    private func pickJingleURL(settings: BGMSettings, placement: JinglePlacement) -> URL? {
        switch placement {
        case .opening:
            return assetPicker.pickAudioFile(from: settings.openingJingleSource, role: .openingJingle)
        case .closing:
            return assetPicker.pickAudioFile(from: settings.closingJingleSource, role: .closingJingle)
        }
    }

    private func isJingleEnabled(settings: BGMSettings, placement: JinglePlacement) -> Bool {
        switch placement {
        case .opening:
            return settings.isOpeningJingleEnabled
        case .closing:
            return settings.isClosingJingleEnabled
        }
    }

    private func clampedVolume(_ value: Double) -> Float {
        Float(min(1, max(0, value)))
    }
}
