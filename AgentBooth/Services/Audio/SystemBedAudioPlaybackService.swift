import AVFoundation
import Foundation

/// Bed BGM / ジングル再生に必要な `AVAudioPlayer` の最小インターフェース。
protocol BedAudioPlayer: AnyObject {
    var numberOfLoops: Int { get set }
    var volume: Float { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }

    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
    func pause()
}

extension AVAudioPlayer: BedAudioPlayer {}

/// システムの音声プレイヤーでベッド BGM とジングルを再生するサービス。
actor SystemBedAudioPlaybackService: BedAudioPlaybackServiceProtocol {
    private let assetPicker: AudioAssetPicker
    private let makeAudioPlayer: @Sendable (URL) throws -> any BedAudioPlayer
    private var bedPlayer: (any BedAudioPlayer)?
    private var jinglePlayer: (any BedAudioPlayer)?
    private var preparedOpeningJingleURL: URL?
    private var preparedClosingJingleURL: URL?
    private var fadeGeneration = 0
    private var isPaused = false

    init(
        assetPicker: AudioAssetPicker = AudioAssetPicker(),
        makeAudioPlayer: @escaping @Sendable (URL) throws -> any BedAudioPlayer = {
            try AVAudioPlayer(contentsOf: $0)
        }
    ) {
        self.assetPicker = assetPicker
        self.makeAudioPlayer = makeAudioPlayer
    }

    func prepareJingle(settings: BGMSettings, placement: JinglePlacement) async -> Double {
        setPreparedJingleURL(nil, placement: placement)
        guard isJingleEnabled(settings: settings, placement: placement),
              let url = pickJingleURL(settings: settings, placement: placement),
              let player = try? makeAudioPlayer(url) else {
            return 0
        }
        setPreparedJingleURL(url, placement: placement)
        return max(0, player.duration)
    }

    func playJingle(settings: BGMSettings, placement: JinglePlacement) async -> Double {
        let url = takePreparedJingleURL(placement: placement)
        guard isJingleEnabled(settings: settings, placement: placement),
              let url,
              let player = try? makeAudioPlayer(url) else {
            return 0
        }

        jinglePlayer?.stop()
        player.numberOfLoops = 0
        player.volume = clampedVolume(settings.jingleVolume)
        _ = player.prepareToPlay()
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
              let player = try? makeAudioPlayer(url) else {
            return
        }

        bedPlayer?.stop()
        player.numberOfLoops = -1
        player.volume = 0
        _ = player.prepareToPlay()
        bedPlayer = player
        isPaused = false
        guard player.play() else {
            bedPlayer = nil
            return
        }

        let generation = beginFade()
        _ = await fade(
            player: player,
            targetVolume: clampedVolume(settings.bedVolume),
            durationSeconds: settings.bedFadeInDuration,
            generation: generation
        )
    }

    func fadeOutAndStopBed(settings: BGMSettings) async {
        guard let player = bedPlayer else {
            return
        }
        let generation = beginFade()
        let didComplete = await fade(
            player: player,
            targetVolume: 0,
            durationSeconds: settings.bedFadeOutDuration,
            generation: generation
        )
        if didComplete, fadeGeneration == generation, bedPlayer === player {
            player.stop()
            bedPlayer = nil
        }
    }

    func stopPlayback() async {
        _ = beginFade()
        bedPlayer?.stop()
        jinglePlayer?.stop()
        bedPlayer = nil
        jinglePlayer = nil
        preparedOpeningJingleURL = nil
        preparedClosingJingleURL = nil
        isPaused = false
    }

    func pausePlayback() async {
        bedPlayer?.pause()
        jinglePlayer?.pause()
        isPaused = true
    }

    func resumePlayback() async {
        if let bedPlayer, !bedPlayer.isPlaying {
            _ = bedPlayer.play()
        }
        if let jinglePlayer, !jinglePlayer.isPlaying {
            _ = jinglePlayer.play()
        }
        isPaused = false
    }

    private func fade(
        player: any BedAudioPlayer,
        targetVolume: Float,
        durationSeconds: Double,
        generation: Int
    ) async -> Bool {
        guard fadeGeneration == generation else {
            return false
        }
        guard durationSeconds > 0 else {
            player.volume = targetVolume
            return true
        }

        let steps = 20
        let startVolume = player.volume
        let stepInterval = durationSeconds / Double(steps)
        let volumeDelta = targetVolume - startVolume

        for indexValue in 1...steps {
            guard await waitUntilFadeCanContinue(generation: generation),
                  bedPlayer === player || jinglePlayer === player else {
                return false
            }
            player.volume = startVolume + volumeDelta * Float(indexValue) / Float(steps)
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, stepInterval) * 1_000_000_000))
        }
        return fadeGeneration == generation
    }

    private func beginFade() -> Int {
        fadeGeneration &+= 1
        return fadeGeneration
    }

    private func waitUntilFadeCanContinue(generation: Int) async -> Bool {
        while isPaused {
            guard fadeGeneration == generation else {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return fadeGeneration == generation
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

    private func setPreparedJingleURL(_ url: URL?, placement: JinglePlacement) {
        switch placement {
        case .opening:
            preparedOpeningJingleURL = url
        case .closing:
            preparedClosingJingleURL = url
        }
    }

    private func takePreparedJingleURL(placement: JinglePlacement) -> URL? {
        let url: URL?
        switch placement {
        case .opening:
            url = preparedOpeningJingleURL
            preparedOpeningJingleURL = nil
        case .closing:
            url = preparedClosingJingleURL
            preparedClosingJingleURL = nil
        }
        return url
    }

    private func clampedVolume(_ value: Double) -> Float {
        Float(min(1, max(0, value)))
    }
}
