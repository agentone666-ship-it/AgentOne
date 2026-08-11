import CoreGraphics
import Foundation

/// The semantic source of a Return key screenshot. The production capture
/// adapter must never label a full-window screenshot as submitted input.
public enum ReturnInputCaptureSource: String, Codable, Sendable {
    case focusedInput
    case caretNeighborhood
    case inferredComposerRegion

    public var userFacingName: String {
        switch self {
        case .focusedInput:
            "聚焦输入框"
        case .caretNeighborhood:
            "光标附近输入区域"
        case .inferredComposerRegion:
            "候选输入区域"
        }
    }
}

/// A crop rectangle normalized to the captured window image. Unlike Vision's
/// OCR rectangles, this uses the image crop coordinate convention and is only
/// consumed by the screenshot adapter.
public struct ReturnInputCaptureRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var source: ReturnInputCaptureSource

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        source: ReturnInputCaptureSource
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.source = source
    }

    public var area: Double { max(0, width) * max(0, height) }
}

/// OCR metadata used to choose between direct and vertically mirrored AX
/// coordinate candidates without exposing window-wide OCR to submittedText.
public struct ReturnInputOCRCandidate: Equatable, Sendable {
    public var id: Int
    public var source: ReturnInputCaptureSource
    public var recognizedText: String?
    public var submittedText: String?
    public var recognizedLineCount: Int
    public var averageConfidence: Double

    public init(
        id: Int,
        source: ReturnInputCaptureSource,
        recognizedText: String?,
        submittedText: String?,
        recognizedLineCount: Int,
        averageConfidence: Double
    ) {
        self.id = id
        self.source = source
        self.recognizedText = recognizedText
        self.submittedText = submittedText
        self.recognizedLineCount = recognizedLineCount
        self.averageConfidence = averageConfidence
    }
}

/// Pure, interface-testable contract for Return input capture.
public enum ReturnInputCaptureContract {
    /// Uses a *full-display* OCR pass only to locate the most likely composer
    /// line inside the frontmost window. The returned regions are still small
    /// window-relative ROIs; callers must run a second OCR pass on those ROIs
    /// and must never use this full-screen text as submitted content.
    ///
    /// This deliberately accepts both AX geometry and Vision geometry. AX can
    /// point at a document/web area instead of the composer, while Vision can
    /// see the actual line the user just submitted. The best candidate is the
    /// one that is closest to the caret/focused element and has the strongest
    /// textual overlap with the pre-Return draft.
    public static func regionsFromFullScreenOCR(
        lines: [NormalizedOCRLine],
        focusedFrame: CGRect?,
        caretFrame: CGRect?,
        windowFrame: CGRect,
        displayFrame: CGRect,
        referenceText: String?,
        interactionPoint: CGPoint? = nil
    ) -> [ReturnInputCaptureRegion] {
        guard windowFrame.width > 1,
              windowFrame.height > 1,
              displayFrame.width > 1,
              displayFrame.height > 1 else {
            return []
        }

        let interactionPoints: [CGPoint] = interactionPoint.map { point in
            // AppKit mouse locations use a bottom-left origin while Vision
            // observations use a bottom-left origin inside the display. A
            // second mirrored point keeps this contract safe on displays whose
            // ScreenCaptureKit frame is reported in the opposite convention.
            uniquePoints([
                point,
                mirrored(point, within: displayFrame)
            ]).filter { candidate in
                distance(displayFrame, to: candidate) <= 4
            }
        } ?? []
        let clippedWindow = windowFrame.intersection(displayFrame)
        guard !clippedWindow.isNull else { return [] }

        // A compact AX focus is the strongest signal that the user is in a
        // composer.  Full-screen OCR is allowed to refine that box, but a
        // matching sentence in the chat history/message list must not be
        // mistaken for the composer after Return clears the field.
        let clippedFocused = focusedFrame.flatMap { $0.intersection(clippedWindow) }
            .flatMap { $0.isNull ? nil : $0 }
        let focusedIsCompact: Bool = {
            guard let focused = clippedFocused else { return false }
            let widthRatio = focused.width / max(1, clippedWindow.width)
            let heightRatio = focused.height / max(1, clippedWindow.height)
            return widthRatio <= 0.98
                && heightRatio <= 0.72
                && (widthRatio * heightRatio) <= 0.55
        }()
        let clippedCaret = caretFrame.flatMap { $0.intersection(clippedWindow) }
            .flatMap { $0.isNull ? nil : $0 }
        let focusedSupportsInteraction = interactionPoints.isEmpty || interactionPoints.contains { point in
            guard let focused = clippedFocused else { return false }
            return distance(focused, to: point) <= max(24, focused.height * 0.35)
        }
        let effectiveTarget = clippedCaret
            ?? ((focusedIsCompact && focusedSupportsInteraction) ? clippedFocused : nil)

        struct Placement {
            let frame: CGRect
            let text: String
            let score: Double
        }

        let reference = cleaned(referenceText)
        let placements: [Placement] = lines.compactMap { line in
            guard let text = cleaned(line.text),
                  !looksLikeChrome(text),
                  contentCharacterCount(text) >= 2,
                  line.width > 0,
                  line.height > 0 else {
                return nil
            }

            let direct = CGRect(
                x: displayFrame.minX + line.x * displayFrame.width,
                y: displayFrame.minY + line.y * displayFrame.height,
                width: line.width * displayFrame.width,
                height: line.height * displayFrame.height
            )
            let mirrored = CGRect(
                x: direct.minX,
                y: displayFrame.minY + (1 - line.y - line.height) * displayFrame.height,
                width: direct.width,
                height: direct.height
            )
            let candidates = [direct, mirrored]
                .map { $0.intersection(clippedWindow) }
                .filter { !$0.isNull && $0.width > 2 && $0.height > 2 }
            guard let frame = candidates.max(by: { lhs, rhs in
                let lhsOverlap = overlapRatio(lhs, with: effectiveTarget)
                let rhsOverlap = overlapRatio(rhs, with: effectiveTarget)
                if abs(lhsOverlap - rhsOverlap) > 0.01 {
                    return lhsOverlap < rhsOverlap
                }
                if !interactionPoints.isEmpty {
                    let lhsDistance = interactionPoints.map { distance(lhs, to: $0) }.min() ?? .greatestFiniteMagnitude
                    let rhsDistance = interactionPoints.map { distance(rhs, to: $0) }.min() ?? .greatestFiniteMagnitude
                    if abs(lhsDistance - rhsDistance) > 1 {
                        return lhsDistance > rhsDistance
                    }
                }
                return distance(lhs, to: effectiveTarget) > distance(rhs, to: effectiveTarget)
            }) else {
                return nil
            }

            if focusedIsCompact && focusedSupportsInteraction {
                // Keep the full-screen locator inside (or immediately on the
                // edge of) the compact focused element.  This is what prevents
                // the just-sent bubble, sidebar, or history row from winning
                // merely because its OCR text matches the draft exactly.
                let overlap = overlapRatio(frame, with: clippedFocused)
                let edgeDistance = distance(frame, to: clippedFocused)
                guard overlap >= 0.08 || edgeDistance <= max(18, clippedFocused?.height ?? 18) else {
                    return nil
                }
            } else if let caret = clippedCaret {
                // For large editors/terminal surfaces the caret is the actual
                // submission anchor.  A line elsewhere in the document is not
                // a valid Return input candidate.
                let edgeDistance = distance(frame, to: caret)
                guard overlapRatio(frame, with: caret) >= 0.02
                    || edgeDistance <= max(42, caret.height * 3) else {
                    return nil
                }
            } else if !interactionPoints.isEmpty {
                // In apps such as WeChat the focused AX element is often the
                // whole web/chat surface. The last click before typing is the
                // only reliable focus signal, so reject OCR lines that are not
                // close to that click. This prevents identical history text or
                // sidebar rows from winning after the composer clears.
                let anchorDistance = interactionPoints.map { distance(frame, to: $0) }.min() ?? .greatestFiniteMagnitude
                let maxAnchorDistance = max(180, clippedWindow.height * 0.24)
                guard anchorDistance <= maxAnchorDistance else { return nil }
            }

            let localY = Double((frame.midY - clippedWindow.minY) / clippedWindow.height)
            var score = min(max(line.confidence, 0), 1) * 14
            score += max(0, 0.72 - localY) * 30
            score += sentenceLike(text) ? 10 : 0
            if let effectiveTarget {
                let normalizedDistance = Double(distance(frame, to: effectiveTarget))
                    / Double(max(windowFrame.width, windowFrame.height))
                score += max(0, 1 - normalizedDistance) * 80
            }
            if !interactionPoints.isEmpty {
                let anchorDistance = interactionPoints.map { distance(frame, to: $0) }.min() ?? .greatestFiniteMagnitude
                let normalizedDistance = Double(anchorDistance)
                    / Double(max(windowFrame.width, windowFrame.height))
                score += max(0, 1 - normalizedDistance) * 240
            }
            if let reference {
                let similarity = textSimilarity(reference, text)
                score += similarity * 220
                if isSubstringMatch(reference, text) {
                    score += 120
                }
            }
            return Placement(frame: frame, text: text, score: score)
        }

        guard let best = placements.max(by: { $0.score < $1.score }) else { return [] }
        let verticalTolerance = max(
            42,
            best.frame.height * 3.5,
            clippedWindow.height * 0.04
        )
        var selected = placements.filter { candidate in
            verticalGap(candidate.frame, best.frame) <= verticalTolerance
                && horizontalOverlap(candidate.frame, best.frame) >= 0.08
        }
        selected.sort { $0.frame.minY < $1.frame.minY }
        let minX = selected.map(\.frame.minX).min() ?? best.frame.minX
        let maxX = selected.map(\.frame.maxX).max() ?? best.frame.maxX
        let minY = selected.map(\.frame.minY).min() ?? best.frame.minY
        let maxY = selected.map(\.frame.maxY).max() ?? best.frame.maxY
        let inferredHeight = max(84, maxY - minY + 56)
        let inferredWidth = max(180, maxX - minX + 56)
        let regionFrame = CGRect(
            x: minX - 28,
            y: minY - 28,
            width: inferredWidth,
            height: inferredHeight
        )
        var result: [ReturnInputCaptureRegion] = []
        appendMirroredRegions(
            regionFrame,
            source: .focusedInput,
            windowFrame: windowFrame,
            to: &result
        )
        return result
    }

    /// Plans small ROI candidates from Accessibility geometry. A large focused
    /// text surface (for example a terminal scrollback buffer or document) is
    /// deliberately rejected as an "input box" and reduced to a caret strip.
    public static func regions(
        focusedFrame: CGRect?,
        caretFrame: CGRect?,
        windowFrame: CGRect,
        interactionPoint: CGPoint? = nil,
        interactionCoordinateFrame: CGRect? = nil
    ) -> [ReturnInputCaptureRegion] {
        guard windowFrame.width > 1, windowFrame.height > 1 else { return [] }
        var result: [ReturnInputCaptureRegion] = []
        let interactionPoints = interactionPoint.map { point in
            uniquePoints([
                point,
                mirrored(point, within: interactionCoordinateFrame ?? windowFrame)
            ]).filter { candidate in
                distance(windowFrame, to: candidate) <= 4
            }
        } ?? []

        if let focused = clipped(focusedFrame, to: windowFrame) {
            let widthRatio = focused.width / windowFrame.width
            let heightRatio = focused.height / windowFrame.height
            let areaRatio = widthRatio * heightRatio
            let supportsInteraction = interactionPoints.isEmpty || interactionPoints.contains { point in
                distance(focused, to: point) <= max(24, focused.height * 0.35)
            }
            if widthRatio <= 0.98,
               heightRatio <= 0.72,
               areaRatio <= 0.55,
               supportsInteraction {
                let horizontalPadding = max(8, min(28, focused.width * 0.04))
                let verticalPadding = max(8, min(24, focused.height * 0.20))
                appendMirroredRegions(
                    focused.insetBy(dx: -horizontalPadding, dy: -verticalPadding),
                    source: .focusedInput,
                    windowFrame: windowFrame,
                    to: &result
                )
            }
        }

        if let caret = clipped(caretFrame, to: windowFrame) {
            let focused = clipped(focusedFrame, to: windowFrame)
            let focusedWidthRatio = (focused?.width ?? windowFrame.width) / windowFrame.width
            let horizontalInset = max(18, windowFrame.width * 0.07)
            let minX: CGFloat
            let width: CGFloat
            if let focused, focusedWidthRatio >= 0.15, focusedWidthRatio <= 0.94 {
                minX = focused.minX
                width = focused.width
            } else {
                minX = windowFrame.minX + horizontalInset
                width = windowFrame.width - horizontalInset * 2
            }

            let stripHeight = max(96, min(220, windowFrame.height * 0.24))
            let strip = CGRect(
                x: minX,
                y: caret.midY - stripHeight * 0.56,
                width: width,
                height: stripHeight
            )
            appendMirroredRegions(
                strip,
                source: .caretNeighborhood,
                windowFrame: windowFrame,
                to: &result
            )
        }

        if result.isEmpty, !interactionPoints.isEmpty {
            // Accessibility may expose only the surrounding chat/web surface.
            // Keep a click-anchored input-sized fallback instead of falling
            // back to a generic upper/lower window strip.
            for point in interactionPoints {
                let width = max(180, min(windowFrame.width * 0.82, windowFrame.width - 36))
                let height = max(84, min(220, windowFrame.height * 0.24))
                let frame = CGRect(
                    x: min(max(point.x - width / 2, windowFrame.minX + 18), windowFrame.maxX - width - 18),
                    y: point.y - height * 0.56,
                    width: width,
                    height: height
                )
                appendMirroredRegions(
                    frame,
                    source: .caretNeighborhood,
                    windowFrame: windowFrame,
                    to: &result
                )
            }
        }

        // Last-resort strips are still input-sized crops. They are never the
        // whole window and their OCR is never joined with window-wide OCR.
        if result.isEmpty {
            appendUnique(
                ReturnInputCaptureRegion(
                    x: 0.10,
                    y: 0.52,
                    width: 0.80,
                    height: 0.36,
                    source: .inferredComposerRegion
                ),
                to: &result
            )
            appendUnique(
                ReturnInputCaptureRegion(
                    x: 0.10,
                    y: 0.12,
                    width: 0.80,
                    height: 0.36,
                    source: .inferredComposerRegion
                ),
                to: &result
            )
        }

        return result.filter { region in
            region.width >= 0.04
                && region.height >= 0.025
                && region.area > 0
                && region.area <= 0.55
        }
    }

    /// Chooses the crop whose OCR most closely supports the Accessibility
    /// draft. Without a draft, focused/caret crops outrank heuristic strips and
    /// compact input-like OCR outranks large blocks of text.
    public static func selectOCRCandidate(
        _ candidates: [ReturnInputOCRCandidate],
        referenceText: String?
    ) -> ReturnInputOCRCandidate? {
        candidates.max { lhs, rhs in
            score(lhs, referenceText: referenceText) < score(rhs, referenceText: referenceText)
        }
    }

    /// Only ROI OCR belongs in `screenText`; background page Context is already
    /// provided independently by Accessibility and must not pollute submission.
    public static func modelScreenText(from recognizedInputText: String?, limit: Int = 8_000) -> String? {
        guard let text = cleaned(recognizedInputText) else { return nil }
        return "回车输入区域 OCR：\n\(String(text.prefix(limit)))"
    }

    private static func score(
        _ candidate: ReturnInputOCRCandidate,
        referenceText: String?
    ) -> Double {
        let sourceScore: Double
        switch candidate.source {
        case .focusedInput: sourceScore = 70
        case .caretNeighborhood: sourceScore = 55
        case .inferredComposerRegion: sourceScore = 20
        }

        let text = cleaned(candidate.submittedText) ?? cleaned(candidate.recognizedText)
        let characterCount = text.map(contentCharacterCount) ?? 0
        let compactnessPenalty = Double(max(0, candidate.recognizedLineCount - 8)) * 5
        var total = sourceScore
            + Double(min(characterCount, 180)) * 0.18
            + min(max(candidate.averageConfidence, 0), 1) * 10
            - compactnessPenalty

        if let reference = cleaned(referenceText), let text {
            let similarity = textSimilarity(reference, text)
            total += similarity * 180
            if similarity < 0.18 {
                // A mirrored crop full of unrelated sidebar/history text must
                // not beat an empty-but-correct composer that was cleared just
                // after Return reached the application.
                total -= 48
            }
            let referenceKey = comparisonKey(reference)
            let textKey = comparisonKey(text)
            if !referenceKey.isEmpty,
               (referenceKey.contains(textKey) || textKey.contains(referenceKey)) {
                total += 35
            }
        } else if cleaned(referenceText) != nil {
            total += 8
        }
        return total
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(comparisonKey(lhs))
        let right = Array(comparisonKey(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let longest = max(left.count, right.count)
        let shortest = min(left.count, right.count)
        guard Double(shortest) / Double(longest) >= 0.25 else { return 0 }
        let distance = levenshteinDistance(left, right)
        return max(0, 1 - Double(distance) / Double(longest))
    }

    private static func isSubstringMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = comparisonKey(lhs)
        let right = comparisonKey(rhs)
        guard left.count >= 2, right.count >= 2 else { return false }
        return left.contains(right) || right.contains(left)
    }

    private static func sentenceLike(_ value: String) -> Bool {
        value.range(of: "[。！？!?，,；;：:]", options: .regularExpression) != nil
    }

    private static func looksLikeChrome(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = [
            "chatgpt", "codex", "send", "发送", "cancel", "取消", "output", "输出",
            "full access", "完全访问", "sources", "来源"
        ]
        if exact.contains(normalized) { return true }
        if normalized.range(of: #"^(?:tip|thinking|context|tokens?|model|session|cached|usage|cost)\s*[:：]"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: #"^\d+(?:\.\d+)?\s+(?:sol|tokens?|tok)(?:\s+\S{1,8})?$"#, options: .regularExpression) != nil {
            return true
        }
        return normalized.range(of: #"^[\d:：./ -]+$"#, options: .regularExpression) != nil
    }

    private static func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let overlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        return overlap / max(1, min(lhs.width, rhs.width))
    }

    private static func verticalGap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY, 0)
    }

    private static func overlapRatio(_ lhs: CGRect, with rhs: CGRect?) -> CGFloat {
        guard let rhs, !rhs.isNull, lhs.width > 0, lhs.height > 0 else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return (intersection.width * intersection.height) / max(1, lhs.width * lhs.height)
    }

    private static func distance(_ lhs: CGRect, to rhs: CGRect?) -> CGFloat {
        guard let rhs else { return 0 }
        let dx = max(rhs.minX - lhs.maxX, lhs.minX - rhs.maxX, 0)
        let dy = max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY, 0)
        return hypot(dx, dy)
    }

    private static func distance(_ lhs: CGRect, to rhs: CGPoint) -> CGFloat {
        let dx = max(rhs.x - lhs.maxX, lhs.minX - rhs.x, 0)
        let dy = max(rhs.y - lhs.maxY, lhs.minY - rhs.y, 0)
        return hypot(dx, dy)
    }

    private static func mirrored(_ point: CGPoint, within frame: CGRect) -> CGPoint {
        CGPoint(
            x: point.x,
            y: frame.minY + frame.maxY - point.y
        )
    }

    private static func uniquePoints(_ points: [CGPoint]) -> [CGPoint] {
        points.reduce(into: []) { result, point in
            guard !result.contains(where: {
                abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5
            }) else { return }
            result.append(point)
        }
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, leftCharacter) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func comparisonKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func contentCharacterCount(_ value: String) -> Int {
        value.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func clipped(_ rect: CGRect?, to windowFrame: CGRect) -> CGRect? {
        guard let rect, rect.width > 1, rect.height >= 0 else { return nil }
        let clipped = rect.intersection(windowFrame)
        guard !clipped.isNull, clipped.width > 1, clipped.height >= 0 else { return nil }
        return clipped
    }

    private static func appendMirroredRegions(
        _ frame: CGRect,
        source: ReturnInputCaptureSource,
        windowFrame: CGRect,
        to result: inout [ReturnInputCaptureRegion]
    ) {
        guard let clipped = clipped(frame, to: windowFrame) else { return }
        let x = (clipped.minX - windowFrame.minX) / windowFrame.width
        let width = clipped.width / windowFrame.width
        let height = clipped.height / windowFrame.height
        let directY = (clipped.minY - windowFrame.minY) / windowFrame.height
        let flippedY = 1 - directY - height
        for y in [directY, flippedY] {
            appendUnique(
                clampedRegion(
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    source: source
                ),
                to: &result
            )
        }
    }

    private static func clampedRegion(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        source: ReturnInputCaptureSource
    ) -> ReturnInputCaptureRegion {
        let minX = min(max(Double(x), 0), 1)
        let minY = min(max(Double(y), 0), 1)
        let maxX = min(max(Double(x + width), 0), 1)
        let maxY = min(max(Double(y + height), 0), 1)
        return ReturnInputCaptureRegion(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY),
            source: source
        )
    }

    private static func appendUnique(
        _ region: ReturnInputCaptureRegion,
        to result: inout [ReturnInputCaptureRegion]
    ) {
        let duplicate = result.contains { existing in
            existing.source == region.source
                && abs(existing.x - region.x) < 0.002
                && abs(existing.y - region.y) < 0.002
                && abs(existing.width - region.width) < 0.002
                && abs(existing.height - region.height) < 0.002
        }
        if !duplicate { result.append(region) }
    }
}
