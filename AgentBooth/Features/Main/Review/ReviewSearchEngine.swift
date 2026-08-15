import Foundation

/// レビュー画面の全セグメントを横断する検索・置換の純関数群。
/// ヒット位置は `NSRange`（UTF-16 オフセット）で表現する。`Range<String.Index>` はセグメントを
/// 跨いで持ち回ると危険なため使わない。
enum ReviewSearchEngine {
    /// 全セグメントの発話指示・発話テキストからヒット位置を探す。
    /// 出現順は「セグメント順 → 発話指示 → 発話行の並び順」。
    static func findMatches(in segments: [ReviewSegmentDraft], query: String, isCaseSensitive: Bool) -> [ReviewMatch] {
        guard !query.isEmpty else { return [] }

        var matches: [ReviewMatch] = []
        for segment in segments {
            for range in findRanges(in: segment.sceneDirection, query: query, isCaseSensitive: isCaseSensitive) {
                matches.append(ReviewMatch(segmentID: segment.id, target: .sceneDirection, range: range))
            }
            for line in segment.lines {
                for range in findRanges(in: line.text, query: query, isCaseSensitive: isCaseSensitive) {
                    matches.append(ReviewMatch(segmentID: segment.id, target: .line(line.id), range: range))
                }
            }
        }
        return matches
    }

    /// クエリに一致する全箇所を置換する。`NSString.replacingOccurrences` を使うため、
    /// 置換文字列がクエリを含む場合（例: "AA" → "AAA"）でも再走査による無限展開は起きない。
    static func replacingAll(
        in segments: [ReviewSegmentDraft],
        query: String,
        replacement: String,
        isCaseSensitive: Bool
    ) -> [ReviewSegmentDraft] {
        guard !query.isEmpty else { return segments }
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]

        var updated = segments
        for segmentIndex in updated.indices {
            updated[segmentIndex].sceneDirection = replacingAllOccurrences(
                in: updated[segmentIndex].sceneDirection, query: query, replacement: replacement, options: options
            )
            for lineIndex in updated[segmentIndex].lines.indices {
                updated[segmentIndex].lines[lineIndex].text = replacingAllOccurrences(
                    in: updated[segmentIndex].lines[lineIndex].text, query: query, replacement: replacement, options: options
                )
            }
        }
        return updated
    }

    /// 指定した1件のヒットだけを置換する。
    static func replacing(_ match: ReviewMatch, in segments: [ReviewSegmentDraft], replacement: String) -> [ReviewSegmentDraft] {
        var updated = segments
        guard let segmentIndex = updated.firstIndex(where: { $0.id == match.segmentID }) else { return segments }

        switch match.target {
        case .sceneDirection:
            updated[segmentIndex].sceneDirection = replacingRange(
                match.range, in: updated[segmentIndex].sceneDirection, with: replacement
            )
        case .line(let lineID):
            guard let lineIndex = updated[segmentIndex].lines.firstIndex(where: { $0.id == lineID }) else { return segments }
            updated[segmentIndex].lines[lineIndex].text = replacingRange(
                match.range, in: updated[segmentIndex].lines[lineIndex].text, with: replacement
            )
        }
        return updated
    }

    /// 検索ヒット部分をハイライトした `AttributedString` を返す。
    static func highlighted(_ text: String, query: String, isCaseSensitive: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }

        for nsRange in findRanges(in: text, query: query, isCaseSensitive: isCaseSensitive) {
            guard let stringRange = Range(nsRange, in: text),
                  let attributedRange = Range(stringRange, in: attributed) else { continue }
            attributed[attributedRange].backgroundColor = .yellow.opacity(0.5)
        }
        return attributed
    }

    // MARK: - Helpers

    private static func findRanges(in text: String, query: String, isCaseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let nsText = text as NSString
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]

        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)
        while searchRange.location < nsText.length {
            let found = nsText.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let nextLocation = found.location + max(found.length, 1)
            guard nextLocation < nsText.length else { break }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }
        return ranges
    }

    private static func replacingRange(_ range: NSRange, in text: String, with replacement: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    private static func replacingAllOccurrences(
        in text: String,
        query: String,
        replacement: String,
        options: NSString.CompareOptions
    ) -> String {
        guard !text.isEmpty else { return text }
        let nsText = text as NSString
        return nsText.replacingOccurrences(of: query, with: replacement, options: options, range: NSRange(location: 0, length: nsText.length))
    }
}
