import XCTest
@testable import AgentBooth

final class ReviewSearchEngineTests: XCTestCase {
    // MARK: - findMatches

    func testFindMatchesFindsHitsInSceneDirectionAndLinesAcrossSegments() {
        let segments = [
            makeSegment(sceneDirection: "深夜のトーン", lines: ["こんばんは"]),
            makeSegment(sceneDirection: "朝の挨拶", lines: ["おはよう", "こんにちは"]),
        ]
        let matches = ReviewSearchEngine.findMatches(in: segments, query: "こん", isCaseSensitive: false)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].segmentID, segments[0].id)
        if case .line = matches[0].target {} else { XCTFail("1件目は行のヒットのはず") }
        XCTAssertEqual(matches[1].segmentID, segments[1].id)
    }

    func testFindMatchesReturnsEmptyForEmptyQuery() {
        let segments = [makeSegment(sceneDirection: "深夜", lines: ["こんばんは"])]
        XCTAssertTrue(ReviewSearchEngine.findMatches(in: segments, query: "", isCaseSensitive: false).isEmpty)
    }

    func testFindMatchesRespectsCaseSensitivity() {
        let segments = [makeSegment(sceneDirection: "", lines: ["Hello World"])]

        let insensitive = ReviewSearchEngine.findMatches(in: segments, query: "hello", isCaseSensitive: false)
        XCTAssertEqual(insensitive.count, 1)

        let sensitive = ReviewSearchEngine.findMatches(in: segments, query: "hello", isCaseSensitive: true)
        XCTAssertTrue(sensitive.isEmpty)
    }

    func testFindMatchesFindsMultipleOccurrencesInSameText() {
        let segments = [makeSegment(sceneDirection: "", lines: ["ららら、らら"])]
        let matches = ReviewSearchEngine.findMatches(in: segments, query: "ら", isCaseSensitive: false)
        XCTAssertEqual(matches.count, 5)
    }

    func testFindMatchesHandlesSurrogatePairsWithoutMisalignment() {
        // 絵文字（サロゲートペア）を含むテキストでも、後続の一致が正しく検出できる。
        let segments = [makeSegment(sceneDirection: "", lines: ["🎵ようこそ🎵ようこそ"])]
        let matches = ReviewSearchEngine.findMatches(in: segments, query: "ようこそ", isCaseSensitive: false)
        XCTAssertEqual(matches.count, 2)
    }

    // MARK: - replacingAll

    func testReplacingAllReplacesEveryOccurrenceAndKeepsLineCount() {
        let segments = [makeSegment(sceneDirection: "深夜、女神転生の話", lines: ["女神転生シリーズ", "関係ない行"])]
        let updated = ReviewSearchEngine.replacingAll(in: segments, query: "女神転生", replacement: "メガテン", isCaseSensitive: false)

        XCTAssertEqual(updated[0].sceneDirection, "深夜、メガテンの話")
        XCTAssertEqual(updated[0].lines.count, 2)
        XCTAssertEqual(updated[0].lines[0].text, "メガテンシリーズ")
        XCTAssertEqual(updated[0].lines[1].text, "関係ない行")
    }

    /// 置換文字列がクエリを含む場合（"AA" → "AAA"）でも再走査による無限展開が起きない。
    func testReplacingAllDoesNotExpandWhenReplacementContainsQuery() {
        let segments = [makeSegment(sceneDirection: "", lines: ["AA"])]
        let updated = ReviewSearchEngine.replacingAll(in: segments, query: "A", replacement: "AA", isCaseSensitive: false)
        XCTAssertEqual(updated[0].lines[0].text, "AAAA")
    }

    func testReplacingAllReturnsUnchangedSegmentsForEmptyQuery() {
        let segments = [makeSegment(sceneDirection: "テキスト", lines: ["テキスト"])]
        let updated = ReviewSearchEngine.replacingAll(in: segments, query: "", replacement: "置換後", isCaseSensitive: false)
        XCTAssertEqual(updated, segments)
    }

    // MARK: - replacing(単一ヒット)

    func testReplacingReplacesOnlySpecifiedMatch() {
        let segments = [makeSegment(sceneDirection: "", lines: ["ららら"])]
        let matches = ReviewSearchEngine.findMatches(in: segments, query: "ら", isCaseSensitive: false)
        XCTAssertEqual(matches.count, 3)

        let updated = ReviewSearchEngine.replacing(matches[1], in: segments, replacement: "ロ")

        XCTAssertEqual(updated[0].lines[0].text, "らロら")
    }

    func testReplacingUpdatesSceneDirectionWhenTargetIsSceneDirection() {
        let segments = [makeSegment(sceneDirection: "深夜のトーン", lines: ["本文"])]
        let matches = ReviewSearchEngine.findMatches(in: segments, query: "深夜", isCaseSensitive: false)
        let match = try! XCTUnwrap(matches.first)

        let updated = ReviewSearchEngine.replacing(match, in: segments, replacement: "早朝")

        XCTAssertEqual(updated[0].sceneDirection, "早朝のトーン")
    }

    private func makeSegment(sceneDirection: String, lines: [String]) -> ReviewSegmentDraft {
        let item = ReviewScriptItem(
            id: 0,
            segmentKey: "opening",
            segmentLabel: "オープニング",
            script: RadioScript(
                segmentType: "opening",
                dialogues: lines.enumerated().map { index, text in
                    DialogueLine(speaker: index % 2 == 0 ? "male" : "female", text: text)
                },
                summaryBullets: [],
                track: nil
            ),
            sceneDirection: sceneDirection,
            maleVoiceName: "Charon",
            femaleVoiceName: "Kore"
        )
        return ReviewSegmentDraft(item: item)
    }
}
