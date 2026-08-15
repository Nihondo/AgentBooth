import Foundation
import XCTest
@testable import AgentBooth

final class SystemBedAudioPlaybackServiceTests: XCTestCase {
    func testNewFadeInvalidatesInProgressFadeIn() async throws {
        let audioURL = try makeTemporaryAudioFile(named: "bed.wav")
        let player = FakeBedAudioPlayer(duration: 1, keepsPlaying: true)
        let service = SystemBedAudioPlaybackService { _ in player }
        var settings = BGMSettings()
        settings.isBedEnabled = true
        settings.bedAudioSource = AudioAssetSource(kind: .file, path: audioURL.path)
        settings.bedVolume = 1
        settings.bedFadeInDuration = 0.4
        settings.bedFadeOutDuration = 0.1

        let fadeInTask = Task {
            await service.startBed(settings: settings)
        }
        try await waitUntil {
            player.volumeHistorySnapshot().contains { $0 >= 0.15 }
        }
        let fadeOutStartIndex = player.volumeHistorySnapshot().count

        await service.fadeOutAndStopBed(settings: settings)
        await fadeInTask.value

        let fadeOutVolumes = Array(player.volumeHistorySnapshot().dropFirst(fadeOutStartIndex))
        XCTAssertFalse(fadeOutVolumes.isEmpty)
        let finalVolume = try XCTUnwrap(fadeOutVolumes.last)
        XCTAssertEqual(finalVolume, 0, accuracy: 0.0001)
        XCTAssertTrue(zip(fadeOutVolumes, fadeOutVolumes.dropFirst()).allSatisfy { pair in
            pair.0 >= pair.1
        })
    }

    func testPreparedJingleReusesSameSelectedURLForPlayback() async throws {
        let directoryURL = try makeTemporaryDirectory()
        _ = try makeTemporaryAudioFile(named: "first.wav", in: directoryURL)
        _ = try makeTemporaryAudioFile(named: "second.wav", in: directoryURL)
        let recorder = LockedURLRecorder()
        let service = SystemBedAudioPlaybackService { url in
            recorder.append(url)
            return FakeBedAudioPlayer(duration: 1, keepsPlaying: false)
        }
        var settings = BGMSettings()
        settings.isOpeningJingleEnabled = true
        settings.openingJingleSource = AudioAssetSource(kind: .directory, path: directoryURL.path)

        let preparedDuration = await service.prepareJingle(settings: settings, placement: .opening)
        let playedDuration = await service.playJingle(settings: settings, placement: .opening)
        let replayedDuration = await service.playJingle(settings: settings, placement: .opening)

        let selectedURLs = recorder.snapshot()
        XCTAssertEqual(preparedDuration, 1)
        XCTAssertEqual(playedDuration, 1)
        XCTAssertEqual(replayedDuration, 0)
        XCTAssertEqual(selectedURLs.count, 2)
        XCTAssertEqual(selectedURLs[0], selectedURLs[1])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeTemporaryAudioFile(named name: String, in directoryURL: URL? = nil) throws -> URL {
        let targetDirectory: URL
        if let directoryURL {
            targetDirectory = directoryURL
        } else {
            targetDirectory = try makeTemporaryDirectory()
        }
        let url = targetDirectory.appendingPathComponent(name)
        try Data([0]).write(to: url)
        return url
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private final class FakeBedAudioPlayer: BedAudioPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private let keepsPlaying: Bool
    private var storedVolume: Float = 1
    private var storedIsPlaying = false
    private var volumeHistory: [Float] = []

    var numberOfLoops = 0
    let duration: TimeInterval

    init(duration: TimeInterval, keepsPlaying: Bool) {
        self.duration = duration
        self.keepsPlaying = keepsPlaying
    }

    var volume: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedVolume
        }
        set {
            lock.lock()
            storedVolume = newValue
            volumeHistory.append(newValue)
            lock.unlock()
        }
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsPlaying
    }

    func prepareToPlay() -> Bool { true }

    func play() -> Bool {
        lock.lock()
        storedIsPlaying = keepsPlaying
        lock.unlock()
        return true
    }

    func stop() {
        lock.lock()
        storedIsPlaying = false
        lock.unlock()
    }

    func pause() {
        lock.lock()
        storedIsPlaying = false
        lock.unlock()
    }

    func volumeHistorySnapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return volumeHistory
    }
}

private final class LockedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
