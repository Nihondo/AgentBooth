import XCTest
@testable import AgentBooth

final class AudioAssetPickerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testFileSourceReturnsExistingAudioFile() throws {
        let audioURL = temporaryDirectory.appendingPathComponent("jingle.wav")
        try Data([0]).write(to: audioURL)
        let source = AudioAssetSource(kind: .file, path: audioURL.path)

        let pickedURL = AudioAssetPicker().pickAudioFile(from: source, role: .openingJingle)

        XCTAssertEqual(pickedURL?.standardizedFileURL, audioURL.standardizedFileURL)
    }

    func testDirectorySourceReturnsAudioFileCandidate() throws {
        let audioURL = temporaryDirectory.appendingPathComponent("bed.m4a")
        let textURL = temporaryDirectory.appendingPathComponent("note.txt")
        try Data([0]).write(to: audioURL)
        try Data([0]).write(to: textURL)
        let source = AudioAssetSource(kind: .directory, path: temporaryDirectory.path)

        let pickedURL = AudioAssetPicker().pickAudioFile(from: source, role: .bed)

        XCTAssertEqual(pickedURL?.standardizedFileURL, audioURL.standardizedFileURL)
    }

    func testDirectorySourceReturnsNilWhenNoAudioFileExists() throws {
        let textURL = temporaryDirectory.appendingPathComponent("note.txt")
        try Data([0]).write(to: textURL)
        let source = AudioAssetSource(kind: .directory, path: temporaryDirectory.path)

        let pickedURL = AudioAssetPicker().pickAudioFile(from: source, role: .closingJingle)

        XCTAssertNil(pickedURL)
    }

    func testEmptyAndMissingPathsReturnNil() {
        let picker = AudioAssetPicker()

        XCTAssertNil(picker.pickAudioFile(from: AudioAssetSource(kind: .file, path: ""), role: .bed))
        XCTAssertNil(picker.pickAudioFile(from: AudioAssetSource(kind: .file, path: "/missing/file.wav"), role: .bed))
    }
}
