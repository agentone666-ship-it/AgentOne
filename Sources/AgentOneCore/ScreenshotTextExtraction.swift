import Foundation

/// A Vision OCR line expressed in normalized image coordinates. The origin is
/// the lower-left corner, matching `VNRecognizedTextObservation.boundingBox`.
public struct NormalizedOCRLine: Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double = 1
    ) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var area: Double { max(0, width) * max(0, height) }
}

public struct NormalizedOCRRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }

    func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX <= maxX && pointY >= y && pointY <= maxY
    }

    func intersectionArea(with line: NormalizedOCRLine) -> Double {
        let intersectionWidth = max(0, min(maxX, line.x + line.width) - max(x, line.x))
        let intersectionHeight = max(0, min(maxY, line.y + line.height) - max(y, line.y))
        return intersectionWidth * intersectionHeight
    }
}

/// Pure selection logic shared by the production Vision adapter and the
/// interface harness. Full-window OCR is useful page evidence, but a Return
/// event also needs the much smaller text region that was actually submitted.
public enum ScreenshotTextExtraction {
    public static func fullText(from lines: [NormalizedOCRLine], limit: Int = 12_000) -> String? {
        joined(sorted(lines), limit: limit)
    }

    public static func text(
        in regions: [NormalizedOCRRegion],
        from lines: [NormalizedOCRLine],
        limit: Int = 6_000
    ) -> String? {
        guard !regions.isEmpty else { return nil }
        var best: (text: String, score: Double)?
        for region in regions where region.area > 0 && region.area <= 0.72 {
            let selected = lines.filter { line in
                guard line.area > 0 else { return false }
                guard region.area > 0, region.area <= 0.72 else { return false }
                let overlap = region.intersectionArea(with: line) / line.area
                return overlap >= 0.22 || region.contains(x: line.midX, y: line.midY)
            }

            // Accessibility coordinates can arrive in either screen-axis
            // convention, so callers provide both mirrored candidates. Treat
            // each region independently; joining both would mix the composer
            // with unrelated text from the opposite side of the window.
            let meaningful = selected.filter { line in
                guard let text = cleaned(line.text) else { return false }
                return !looksLikeWindowChrome(text)
            }
            guard let text = joined(sorted(meaningful), limit: limit) else { continue }
            let score = focusedRegionScore(
                meaningful: meaningful,
                rejectedChromeCount: selected.count - meaningful.count
            )
            if best == nil || score > best!.score {
                best = (text, score)
            }
        }
        return best?.text
    }

    /// Last-resort extraction for apps whose Accessibility tree exposes neither
    /// an editor value nor a useful focused-element frame. Chat composers and
    /// terminals normally submit from the lower portion of the window, so this
    /// scores only low, sentence-like OCR lines and rejects common chrome.
    public static func inferredSubmittedText(
        from lines: [NormalizedOCRLine],
        limit: Int = 2_000
    ) -> String? {
        let meaningful = lines.compactMap { line -> (line: NormalizedOCRLine, text: String)? in
            guard line.midY <= 0.45,
                  let text = cleaned(line.text),
                  text.count >= 4,
                  contentCharacterCount(text) >= 3,
                  !looksLikeWindowChrome(text) else {
                return nil
            }
            return (line, text)
        }
        guard !meaningful.isEmpty else { return nil }

        // Prefer the center editor lane before comparing vertical position.
        // A Codex-style three-column window can keep old task titles very low
        // in the left sidebar; those titles are not candidates for the active
        // composer even when they are longer than the submitted sentence.
        let editorLane = meaningful.filter { candidate in
            candidate.line.midX >= 0.18 && candidate.line.midX <= 0.90
        }
        let candidates = editorLane.isEmpty ? meaningful : editorLane

        // The active composer is the lowest meaningful line after footer
        // chrome is removed. Length is only a tie-breaker for OCR fragments on
        // effectively the same baseline. This is intentionally different from
        // full-page summarization: a long paragraph immediately above the
        // composer must never beat the short sentence the user just submitted.
        let best = candidates.min { lhs, rhs in
            if abs(lhs.line.midY - rhs.line.midY) > 0.018 {
                return lhs.line.midY < rhs.line.midY
            }
            return submittedLineScore(lhs.line, text: lhs.text)
                > submittedLineScore(rhs.line, text: rhs.text)
        }
        guard let best else { return nil }

        // Include tightly adjacent wrapped lines above the winning line when
        // they share the same horizontal editor column.
        let bestIsListItem = looksLikeListItem(best.text)
        let related = candidates.filter { candidate in
            let verticalDistance = candidate.line.midY - best.line.midY
            guard verticalDistance >= -0.025, verticalDistance <= 0.055 else { return false }
            guard bestIsListItem || !looksLikeListItem(candidate.text) else { return false }
            let horizontalOverlap = max(
                0,
                min(candidate.line.x + candidate.line.width, best.line.x + best.line.width)
                    - max(candidate.line.x, best.line.x)
            )
            let minimumWidth = max(0.001, min(candidate.line.width, best.line.width))
            return horizontalOverlap / minimumWidth >= 0.55
        }
        return joined(sorted(related.map(\.line)), limit: limit) ?? String(best.text.prefix(limit))
    }

    /// Chooses between OCR from the Accessibility focus rectangle and the
    /// position-based composer inference. A terminal often reports one huge
    /// focus rectangle for its entire scrollback buffer; that candidate must
    /// not override the smaller inferred prompt line.
    public static func preferredSubmittedText(
        focusedRegionText: String?,
        inferredSubmittedText: String?,
        limit: Int = 2_000
    ) -> String? {
        let focused = plausibleCandidate(
            focusedRegionText,
            maximumCharacters: 1_500,
            maximumLines: 8,
            limit: limit
        )
        let inferred = plausibleCandidate(
            inferredSubmittedText,
            maximumCharacters: 2_000,
            maximumLines: 8,
            limit: limit
        )
        guard let focused else { return inferred }
        guard let inferred else { return focused }

        let focusedKey = comparisonKey(focused)
        let inferredKey = comparisonKey(inferred)
        if focusedKey.contains(inferredKey), focusedKey.count > inferredKey.count + 12 {
            return inferred
        }
        if focused.components(separatedBy: .newlines).count
            > inferred.components(separatedBy: .newlines).count + 2 {
            return inferred
        }
        return focused
    }

    private static func sorted(_ lines: [NormalizedOCRLine]) -> [NormalizedOCRLine] {
        lines.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.015 {
                return lhs.midY > rhs.midY
            }
            return lhs.x < rhs.x
        }
    }

    private static func joined(_ lines: [NormalizedOCRLine], limit: Int) -> String? {
        var seen: Set<String> = []
        let text = lines.compactMap { line -> String? in
            guard let text = cleaned(line.text) else { return nil }
            let fingerprint = text.lowercased()
            guard seen.insert(fingerprint).inserted else { return nil }
            return text
        }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func submittedLineScore(_ line: NormalizedOCRLine, text: String) -> Double {
        let length = Double(min(contentCharacterCount(text), 160))
        let bottomness = max(0, 0.46 - line.midY) * 70
        let centered: Double
        if line.midX >= 0.18 && line.midX <= 0.88 {
            centered = 12
        } else if line.midX < 0.14 {
            centered = -14
        } else {
            centered = 0
        }
        let widthBonus = min(max(line.width, 0), 0.75) * 16
        let promptBonus = text.range(
            of: #"^[❯›>$%➜»]\s*"#,
            options: .regularExpression
        ) == nil ? 0 : 10.0
        let sentenceBonus = text.range(of: "[。！？!?，,；;：:]", options: .regularExpression) == nil ? 0 : 7.0
        let confidence = min(max(line.confidence, 0), 1) * 6
        return length * 1.25
            + bottomness
            + centered
            + widthBonus
            + promptBonus
            + sentenceBonus
            + confidence
    }

    private static func focusedRegionScore(
        meaningful lines: [NormalizedOCRLine],
        rejectedChromeCount: Int
    ) -> Double {
        guard !lines.isEmpty else { return -.infinity }
        let contentLength = lines.reduce(into: 0) { total, line in
            total += min(contentCharacterCount(line.text), 120)
        }
        let averageConfidence = lines.reduce(0) { $0 + min(max($1.confidence, 0), 1) }
            / Double(lines.count)
        let averageY = lines.reduce(0) { $0 + $1.midY } / Double(lines.count)
        let sentenceLines = lines.reduce(into: 0) { count, line in
            if line.text.range(of: "[。！？!?，,；;：:]", options: .regularExpression) != nil {
                count += 1
            }
        }
        let bottomPreference = max(0, 0.42 - averageY) * 55
        let clutterPenalty = Double(max(0, lines.count - 5)) * 12
        let chromePenalty = Double(max(0, rejectedChromeCount)) * 3
        return Double(min(contentLength, 260)) * 1.15
            + averageConfidence * 10
            + Double(sentenceLines) * 6
            + bottomPreference
            - clutterPenalty
            - chromePenalty
    }

    private static func contentCharacterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
    }

    private static func looksLikeWindowChrome(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ReturnInputCaptureContract.isLikelyInterfaceChrome(normalized) {
            return true
        }
        if normalized.contains("完全访问") || normalized.contains("full access") {
            return true
        }
        let exactChrome = [
            "chatgpt", "codex", "tokenhub", "完全访问", "full access",
            "发送", "send", "取消", "cancel", "输出", "来源", "展开显示"
        ]
        if exactChrome.contains(normalized) { return true }
        if normalized.range(
            of: "^\\d+(?:\\.\\d+)?\\s+(?:sol|tokens?|tok)(?:\\s+\\S{1,4})?$",
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.contains("sol"),
           normalized.count <= 24,
           normalized.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }
        if normalized.range(
            of: #"^(?:tip|thinking|context|tokens?|model|session|cached|usage|cost)\s*[:：]"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"^(?:ctrl|shift|cmd|esc|tab)(?:\+|\s)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"^\d{1,3}%\s+(?:context|tokens?)\s+(?:left|remaining)$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(of: "^[\\d:：./ -]+$", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeListItem(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:[•●◦▪︎■□◆◇·]|[-*]\s|\d+[.)、]\s*)"#,
            options: .regularExpression
        ) != nil
    }

    private static func plausibleCandidate(
        _ value: String?,
        maximumCharacters: Int,
        maximumLines: Int,
        limit: Int
    ) -> String? {
        guard let text = cleaned(value),
              text.count >= 2,
              text.count <= maximumCharacters,
              text.components(separatedBy: .newlines).count <= maximumLines,
              contentCharacterCount(text) >= 2,
              !looksLikeWindowChrome(text) else {
            return nil
        }
        return String(text.prefix(limit))
    }

    private static func comparisonKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
