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

/// Spatial conventions for chat composers that are known to expose noisy or
/// overly broad Accessibility focus on macOS. These profiles are intentionally
/// conservative: when the focused AX element points at a sidebar row or chat
/// history, Return capture fails closed instead of persisting the wrong text.
public enum ReturnInputComposerProfile: String, Codable, Sendable {
    case generic
    case weChat
    case codex
    case feishu

    public static func resolve(
        bundleIdentifier: String?,
        applicationName: String?
    ) -> ReturnInputComposerProfile {
        let value = [bundleIdentifier, applicationName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if value.contains("com.tencent.xinwechat") || value.contains("wechat") || value.contains("微信") {
            return .weChat
        }
        if value.contains("com.openai.codex") || value.contains("chatgpt") || value.contains("codex") {
            return .codex
        }
        if value.contains("com.bytedance.macos.feishu")
            || value.contains("com.bytedance.ee.larkmac")
            || value.contains("feishu")
            || value.contains("lark")
            || value.contains("飞书") {
            return .feishu
        }
        return .generic
    }

    /// A click may be retained as the Return anchor only when it falls in the
    /// part of a known chat window that can actually contain its composer.
    /// This is intentionally stricter than the OCR envelope: a lower sidebar
    /// conversation row must never become an input hypothesis merely because
    /// the app exposes an AXWebArea instead of a text field.
    public func acceptsInputAnchor(_ point: CGPoint, in windowFrame: CGRect) -> Bool {
        guard windowFrame.width > 1, windowFrame.height > 1,
              windowFrame.insetBy(dx: -4, dy: -4).contains(point) else {
            return false
        }
        if self == .generic { return true }
        return ReturnInputCaptureContract.profileAnchorFrame(
            windowFrame: windowFrame,
            profile: self
        ).contains(point)
    }

    /// Whether Accessibility geometry can be treated as input geometry for a
    /// known app. WeChat and Feishu frequently leave their sidebar search field
    /// exposed as the focused AXTextField even after the user has clicked and
    /// typed in the conversation composer. Keeping this check in the pure Core
    /// contract lets the runtime reject that stale focus before its value can
    /// become the submitted-text reference.
    public func acceptsTrustedInputGeometry(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        ReturnInputCaptureContract.profileAcceptsTrustedGeometry(
            frame: frame,
            windowFrame: windowFrame,
            profile: self
        )
    }

    /// Validates the click that began a typing burst. In known chat apps a
    /// valid composer-zone click is allowed to override stale *sidebar* AX
    /// focus, but it may not override a real focused editor elsewhere in the
    /// main content (for example a Feishu document comment field).
    public func validatesTypingAnchor(
        _ point: CGPoint,
        focusedFrame: CGRect?,
        caretFrame: CGRect?,
        in windowFrame: CGRect
    ) -> Bool {
        guard acceptsInputAnchor(point, in: windowFrame) else { return false }

        if let focusedFrame,
           acceptsTrustedInputGeometry(focusedFrame, in: windowFrame) {
            let widthRatio = focusedFrame.width / max(1, windowFrame.width)
            let heightRatio = focusedFrame.height / max(1, windowFrame.height)
            if widthRatio <= 0.75, heightRatio <= 0.55 {
                let padding = max(16, min(36, focusedFrame.height * 0.35))
                return focusedFrame.insetBy(dx: -padding, dy: -padding).contains(point)
            }
        }

        if let caretFrame,
           acceptsTrustedInputGeometry(caretFrame, in: windowFrame) {
            return caretFrame.insetBy(dx: -160, dy: -64).contains(point)
        }

        // Electron chat surfaces sometimes expose only the surrounding
        // document while their stale sidebar field remains AX-focused. For a
        // known profile, the strict composer zone is then the best available
        // evidence. Generic apps still require concrete AX geometry.
        return self != .generic
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

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// OCR metadata used to choose among independently cropped, spatially anchored
/// input candidates without exposing window-wide OCR to submittedText.
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
    /// Freezes a typing-time ROI inside the hard composer envelope used by a
    /// known chat app. This is intentionally stricter than the general OCR
    /// locator: a pre-Return crop may be trimmed, but it may never move upward
    /// into history or sideways into a conversation sidebar.
    public static func constrainedPreSubmissionRegion(
        _ region: ReturnInputCaptureRegion,
        profile: ReturnInputComposerProfile
    ) -> ReturnInputCaptureRegion? {
        guard region.width > 0,
              region.height > 0,
              region.x.isFinite,
              region.y.isFinite,
              region.width.isFinite,
              region.height.isFinite else {
            return nil
        }

        let bounds = preSubmissionBounds(profile: profile)
        let raw = CGRect(
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height
        ).intersection(bounds)
        guard !raw.isNull,
              raw.width >= 0.04,
              raw.height >= 0.025 else {
            return nil
        }

        if profile != .generic {
            let originalCenter = CGPoint(x: region.midX, y: region.midY)
            guard bounds.contains(originalCenter) else { return nil }
            let retainedArea = Double(raw.width * raw.height) / max(region.area, 0.000_001)
            guard retainedArea >= 0.45 else { return nil }
        }

        return ReturnInputCaptureRegion(
            x: raw.minX,
            y: raw.minY,
            width: raw.width,
            height: raw.height,
            source: region.source
        )
    }

    /// Produces a tighter window-relative crop from meaningful OCR lines found
    /// inside an already-frozen input ROI. Vision lines use a lower-left origin;
    /// ReturnInputCaptureRegion uses the captured image's top-left crop origin.
    public static func tightenedPreSubmissionRegion(
        within region: ReturnInputCaptureRegion,
        meaningfulLines: [NormalizedOCRLine],
        horizontalPadding: Double = 0.018,
        verticalPadding: Double = 0.10
    ) -> ReturnInputCaptureRegion? {
        guard !meaningfulLines.isEmpty else { return nil }
        let minX = meaningfulLines.map(\.x).min() ?? 0
        let maxX = meaningfulLines.map { $0.x + $0.width }.max() ?? 1
        let visionMinY = meaningfulLines.map(\.y).min() ?? 0
        let visionMaxY = meaningfulLines.map { $0.y + $0.height }.max() ?? 1
        let topY = 1 - visionMaxY
        let bottomY = 1 - visionMinY

        let nestedMinX = max(0, minX - horizontalPadding)
        let nestedMaxX = min(1, maxX + horizontalPadding)
        let nestedMinY = max(0, topY - verticalPadding)
        let nestedMaxY = min(1, bottomY + verticalPadding)
        guard nestedMaxX - nestedMinX >= 0.02,
              nestedMaxY - nestedMinY >= 0.02 else {
            return nil
        }

        return ReturnInputCaptureRegion(
            x: region.x + nestedMinX * region.width,
            y: region.y + nestedMinY * region.height,
            width: (nestedMaxX - nestedMinX) * region.width,
            height: (nestedMaxY - nestedMinY) * region.height,
            source: region.source
        )
    }

    public static func meaningfulPreSubmissionLines(
        _ lines: [NormalizedOCRLine]
    ) -> [NormalizedOCRLine] {
        lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  text.reduce(into: 0, { count, character in
                      if character.isLetter || character.isNumber { count += 1 }
                  }) >= 1 else {
                return false
            }
            return !isLikelyInterfaceChrome(text)
        }
    }

    /// Applies app-specific text baselines after the frozen ROI has already
    /// been constrained. This rejects Codex's bottom status/share strip even
    /// when Vision misreads a model label into an unrelated-looking word.
    public static func spatiallyValidPreSubmissionLines(
        _ lines: [NormalizedOCRLine],
        within region: ReturnInputCaptureRegion,
        profile: ReturnInputComposerProfile
    ) -> [NormalizedOCRLine] {
        lines.filter { line in
            let windowMidX = region.x + line.midX * region.width
            let windowMidY = region.y + (1 - line.midY) * region.height
            switch profile {
            case .generic:
                return true
            case .weChat:
                return windowMidX >= 0.28 && windowMidY >= 0.67 && windowMidY <= 0.975
            case .codex:
                return windowMidX >= 0.17 && windowMidY >= 0.57 && windowMidY <= 0.925
            case .feishu:
                return windowMidX >= 0.24 && windowMidY >= 0.61 && windowMidY <= 0.975
            }
        }
    }

    /// Selects only the contiguous text block being submitted from OCR inside
    /// a frozen composer ROI. A reference draft, when available, identifies
    /// the matching wrapped lines. Without one, the lowest meaningful text
    /// block wins; older messages higher in an oversized click fallback do not
    /// get joined into the submission.
    public static func preSubmissionEvidenceLines(
        _ lines: [NormalizedOCRLine],
        referenceText: String?
    ) -> [NormalizedOCRLine] {
        let meaningful = meaningfulPreSubmissionLines(lines)
        guard !meaningful.isEmpty else { return [] }

        let reference = cleaned(referenceText)
        let anchor: NormalizedOCRLine
        if let reference {
            guard let best = meaningful.max(by: {
                preSubmissionReferenceScore($0, reference: reference)
                    < preSubmissionReferenceScore($1, reference: reference)
            }),
            preSubmissionReferenceScore(best, reference: reference) >= 32 else {
                return []
            }
            anchor = best
        } else {
            // Vision's origin is lower-left, so the smallest midY is the line
            // nearest the bottom of the input box after chrome is rejected.
            anchor = meaningful.min { lhs, rhs in
                if abs(lhs.midY - rhs.midY) > 0.018 {
                    return lhs.midY < rhs.midY
                }
                return contentCharacterCount(lhs.text) > contentCharacterCount(rhs.text)
            }!
        }

        var selected = [anchor]
        var selectedIndexes: Set<Int> = []
        if let index = meaningful.firstIndex(of: anchor) {
            selectedIndexes.insert(index)
        }
        let maximumVerticalGap = max(0.055, anchor.height * 1.75)
        var didExpand = true
        while didExpand && selected.count < 8 {
            didExpand = false
            for (index, candidate) in meaningful.enumerated() where !selectedIndexes.contains(index) {
                let isAdjacent = selected.contains { existing in
                    normalizedVerticalGap(candidate, existing) <= maximumVerticalGap
                        && normalizedHorizontalOverlap(candidate, existing) >= 0.08
                }
                guard isAdjacent else { continue }
                if let reference {
                    let lineKey = comparisonKey(candidate.text)
                    let referenceKey = comparisonKey(reference)
                    guard lineKey.count >= 1,
                          referenceKey.contains(lineKey)
                            || textSimilarity(reference, candidate.text) >= 0.20 else {
                        continue
                    }
                }
                selected.append(candidate)
                selectedIndexes.insert(index)
                didExpand = true
            }
        }

        return selected.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.015 {
                return lhs.midY > rhs.midY
            }
            return lhs.x < rhs.x
        }
    }

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
        interactionPoint: CGPoint? = nil,
        profile: ReturnInputComposerProfile = .generic
    ) -> [ReturnInputCaptureRegion] {
        guard windowFrame.width > 1,
              windowFrame.height > 1,
              displayFrame.width > 1,
              displayFrame.height > 1 else {
            return []
        }

        // AX, ScreenCaptureKit and CGEvent locations are normalized by the app
        // into the global Quartz screen space (top-left origin) before they
        // reach this contract. Vision is the sole exception: its normalized
        // OCR boxes use a lower-left origin and are flipped exactly once below.
        // Keeping one canonical space is important. The old implementation
        // emitted both the direct and vertically mirrored crop, which let an
        // identical sentence in chat history beat the real (often cleared)
        // composer after Return.
        let interactionPoints = interactionPoint.map { point in
            distance(displayFrame, to: point) <= 4
                && profileAccepts(point: point, windowFrame: windowFrame, profile: profile)
                ? [point]
                : []
        } ?? []
        let clippedWindow = windowFrame.intersection(displayFrame)
        guard !clippedWindow.isNull else { return [] }

        // A compact AX focus is the strongest signal that the user is in a
        // composer.  Full-screen OCR is allowed to refine that box, but a
        // matching sentence in the chat history/message list must not be
        // mistaken for the composer after Return clears the field.
        let clippedFocused: CGRect? = focusedFrame
            .map { $0.intersection(clippedWindow) }
            .flatMap { frame -> CGRect? in
                guard !frame.isNull,
                      profileAcceptsTrustedGeometry(
                        frame: frame,
                        windowFrame: windowFrame,
                        profile: profile
                      ) else {
                    return nil
                }
                return frame
            }
        let focusedIsCompact: Bool = {
            guard let focused = clippedFocused else { return false }
            let widthRatio = focused.width / max(1, clippedWindow.width)
            let heightRatio = focused.height / max(1, clippedWindow.height)
            return widthRatio <= 0.98
                && heightRatio <= 0.72
                && (widthRatio * heightRatio) <= 0.55
        }()
        let clippedCaret: CGRect? = caretFrame
            .map { $0.intersection(clippedWindow) }
            .flatMap { frame -> CGRect? in
                guard !frame.isNull,
                      profileAcceptsTrustedGeometry(
                        frame: frame,
                        windowFrame: windowFrame,
                        profile: profile
                      ) else {
                    return nil
                }
                return frame
            }
        let focusedSupportsInteraction = interactionPoints.isEmpty || interactionPoints.contains { point in
            guard let focused = clippedFocused else { return false }
            return distance(focused, to: point) <= max(24, focused.height * 0.35)
        }
        let trustedFocused = (focusedIsCompact && focusedSupportsInteraction) ? clippedFocused : nil
        let hasTrustedGeometry = clippedCaret != nil || trustedFocused != nil
        let allowedComposerFrame = hasTrustedGeometry
            ? clippedWindow
            : profileComposerFrame(windowFrame: clippedWindow, profile: profile)
        let effectiveTarget = clippedCaret
            ?? trustedFocused
            ?? interactionPoints.first.map { point in
                CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            }

        let spatialEnvelope: CGRect? = {
            if let caret = clippedCaret {
                if let focused = clippedFocused, focusedIsCompact {
                    let horizontalPadding = max(10, min(24, focused.width * 0.03))
                    let verticalPadding = max(10, min(20, focused.height * 0.16))
                    return focused
                        .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                        .intersection(clippedWindow)
                        .intersection(allowedComposerFrame)
                }
                let horizontalInset = max(18, clippedWindow.width * 0.06)
                let height = max(110, min(220, clippedWindow.height * 0.22))
                return CGRect(
                    x: clippedWindow.minX + horizontalInset,
                    y: caret.midY - height * 0.68,
                    width: max(1, clippedWindow.width - horizontalInset * 2),
                    height: height
                )
                    .intersection(clippedWindow)
                    .intersection(allowedComposerFrame)
            }
            if let focused = trustedFocused {
                let horizontalPadding = max(10, min(24, focused.width * 0.03))
                let verticalPadding = max(10, min(20, focused.height * 0.16))
                return focused
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(clippedWindow)
                    .intersection(allowedComposerFrame)
            }
            if let point = interactionPoints.first {
                let width = max(220, min(clippedWindow.width * 0.86, clippedWindow.width - 28))
                let height = max(96, min(180, clippedWindow.height * 0.18))
                return CGRect(
                    x: min(
                        max(point.x - width / 2, clippedWindow.minX + 14),
                        clippedWindow.maxX - width - 14
                    ),
                    y: point.y - height * 0.62,
                    width: width,
                    height: height
                )
                    .intersection(clippedWindow)
                    .intersection(allowedComposerFrame)
            }
            return nil
        }()

        // Without a caret, a compact focused control, or the click that began
        // the typing burst, OCR text alone cannot identify an input box. Fail
        // closed instead of cropping whichever matching sentence is elsewhere
        // on the page.
        guard let effectiveTarget,
              let spatialEnvelope,
              !spatialEnvelope.isNull else {
            return []
        }

        struct Placement {
            let id: Int
            let frame: CGRect
            let text: String
            let score: Double
            let isPostSubmitRecovery: Bool
        }

        let reference = cleaned(referenceText)
        let bottomComposerAnchor: CGRect? = {
            guard profile != .generic else { return nil }
            let anchor = profileAnchorFrame(windowFrame: clippedWindow, profile: profile)
            let targetIsBottomComposer = effectiveTarget.midY >= anchor.minY
                || interactionPoints.contains(where: anchor.contains)
            return targetIsBottomComposer ? anchor : nil
        }()
        let postSubmitRecoveryFrame: CGRect? = bottomComposerAnchor.map { anchor in
            let maximumLookback = min(280, clippedWindow.height * 0.34)
            let lowerBound = max(
                clippedWindow.minY,
                min(anchor.minY, spatialEnvelope.minY) - maximumLookback
            )
            let upperBound = min(
                clippedWindow.maxY,
                max(anchor.minY + 12, spatialEnvelope.minY + 12)
            )
            let mainContent = profileComposerFrame(windowFrame: clippedWindow, profile: profile)
            return CGRect(
                x: mainContent.minX,
                y: lowerBound,
                width: mainContent.width,
                height: max(1, upperBound - lowerBound)
            ).intersection(clippedWindow)
        }
        let placements: [Placement] = lines.enumerated().compactMap { index, line in
            guard let text = cleaned(line.text),
                  !isLikelyInterfaceChrome(text),
                  contentCharacterCount(text) >= 2,
                  line.width > 0,
                  line.height > 0 else {
                return nil
            }

            // Vision boxes are lower-left normalized. ScreenCaptureKit window
            // and display frames, AX frames, CGEvent points, and CGImage crop
            // rectangles are handled here in the Quartz top-left convention.
            let screenFrame = CGRect(
                x: displayFrame.minX + line.x * displayFrame.width,
                y: displayFrame.minY + (1 - line.y - line.height) * displayFrame.height,
                width: line.width * displayFrame.width,
                height: line.height * displayFrame.height
            ).intersection(clippedWindow)
            guard !screenFrame.isNull,
                  screenFrame.width > 2,
                  screenFrame.height > 2,
                  (hasTrustedGeometry
                    || profileAccepts(frame: screenFrame, windowFrame: windowFrame, profile: profile)) else {
                return nil
            }
            let frame = screenFrame

            // Space is a hard gate. Text similarity is normally only allowed
            // to rank OCR lines that already belong to the same composer/caret
            // band. Known chat apps get one narrow exception: after Return has
            // cleared the composer, an exact copy of the pre-Return draft may
            // be recovered from the immediately adjacent, main-content-only
            // sent-message band. Sidebars and older history stay outside it.
            let envelopeDistance = distance(frame, to: spatialEnvelope)
            let rawIntersection = spatialEnvelope.intersects(frame)
            let intersectsComposer = profile == .generic
                ? rawIntersection
                : rawIntersection && overlapRatio(frame, with: spatialEnvelope) >= 0.25
            let belongsToComposer = intersectsComposer
                || (!rawIntersection && envelopeDistance <= max(6, frame.height * 0.35))
            let isPostSubmitRecovery: Bool = {
                guard !belongsToComposer,
                      let reference,
                      let recoveryFrame = postSubmitRecoveryFrame,
                      recoveryFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
                    return false
                }
                let referenceKey = comparisonKey(reference)
                let textKey = comparisonKey(text)
                guard textKey.count >= 4, referenceKey.count >= 4 else { return false }
                return isSubstringMatch(reference, text)
                    || textSimilarity(reference, text) >= 0.72
            }()
            guard belongsToComposer || isPostSubmitRecovery else {
                return nil
            }

            var score = min(max(line.confidence, 0), 1) * 14
            score += sentenceLike(text) ? 10 : 0
            let normalizedDistance = Double(distance(frame, to: effectiveTarget))
                / Double(max(max(spatialEnvelope.width, spatialEnvelope.height), 1))
            score += max(0, 1 - normalizedDistance) * 180
            score += Double(overlapRatio(frame, with: spatialEnvelope)) * 45
            if let reference {
                let similarity = textSimilarity(reference, text)
                score += similarity * 70
                if isSubstringMatch(reference, text) {
                    score += 30
                }
            }
            if isPostSubmitRecovery {
                score += 22
            }
            return Placement(
                id: index,
                frame: frame,
                text: text,
                score: score,
                isPostSubmitRecovery: isPostSubmitRecovery
            )
        }

        guard let best = placements.max(by: { $0.score < $1.score }) else { return [] }
        let adjacentLineTolerance = max(
            18,
            best.frame.height * 1.1,
            clippedWindow.height * 0.018
        )
        var selected = [best]
        var selectedIDs: Set<Int> = [best.id]
        var didExpand = true
        while didExpand && selected.count < 10 {
            didExpand = false
            for candidate in placements where !selectedIDs.contains(candidate.id) {
                let joinsComposer = selected.contains { existing in
                    candidate.isPostSubmitRecovery == existing.isPostSubmitRecovery
                        && verticalGap(candidate.frame, existing.frame) <= adjacentLineTolerance
                        && horizontalOverlap(candidate.frame, existing.frame) >= 0.08
                }
                guard joinsComposer else { continue }
                selected.append(candidate)
                selectedIDs.insert(candidate.id)
                didExpand = true
            }
        }
        selected.sort { $0.frame.minY < $1.frame.minY }
        let minX = selected.map(\.frame.minX).min() ?? best.frame.minX
        let maxX = selected.map(\.frame.maxX).max() ?? best.frame.maxX
        let minY = selected.map(\.frame.minY).min() ?? best.frame.minY
        let maxY = selected.map(\.frame.maxY).max() ?? best.frame.maxY
        let inferredFrame: CGRect
        if profile == .generic {
            inferredFrame = CGRect(
                x: minX - 28,
                y: minY - 28,
                width: max(180, maxX - minX + 56),
                height: max(72, maxY - minY + 56)
            )
        } else {
            // In known chat apps the footer/toolbar sits immediately below
            // the editable text. Symmetric 28–38 px padding repeatedly pulled
            // Codex's model/usage strip and WeChat toolbar into the evidence.
            // Use the OCR lines themselves as the vertical truth and retain a
            // smaller, asymmetric proof margin around them.
            inferredFrame = CGRect(
                x: minX - 22,
                y: minY - 16,
                width: max(160, maxX - minX + 44),
                height: max(46, maxY - minY + 32)
            )
        }
        let regionFrame: CGRect
        let source: ReturnInputCaptureSource
        if best.isPostSubmitRecovery {
            // This is proof of the text after the app has already moved it out
            // of the composer. Persist only the tight bubble/text neighborhood;
            // never widen back to the focused input, toolbar or sidebar.
            regionFrame = inferredFrame
                .intersection(postSubmitRecoveryFrame ?? clippedWindow)
                .intersection(clippedWindow)
            source = .inferredComposerRegion
        } else if let focused = trustedFocused {
            // The focused input frame is the most useful persisted evidence:
            // it shows the whole composer rather than a tiny OCR word box.
            let paddedFocus = focused
                .insetBy(
                    dx: -max(10, min(24, focused.width * 0.03)),
                    dy: -max(8, min(16, focused.height * 0.12))
                )
                .intersection(clippedWindow)
                .intersection(profileComposerFrame(windowFrame: clippedWindow, profile: profile))
            if profile == .generic {
                regionFrame = paddedFocus
            } else {
                // Electron chat surfaces often expose the composer together
                // with a footer/status strip. The OCR locator has already
                // found the submitted lines, so tighten known app crops around
                // those lines while retaining enough surrounding UI to prove
                // which input box produced them.
                let tightened = inferredFrame.intersection(paddedFocus)
                regionFrame = tightened.width >= 120 && tightened.height >= 42
                    ? tightened
                    : paddedFocus
            }
            source = .focusedInput
        } else {
            regionFrame = inferredFrame
                .intersection(spatialEnvelope.insetBy(dx: -8, dy: -8))
                .intersection(clippedWindow)
            source = .caretNeighborhood
        }
        var result: [ReturnInputCaptureRegion] = []
        appendRegion(
            regionFrame,
            source: source,
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
        interactionCoordinateFrame: CGRect? = nil,
        allowUnanchoredFallback: Bool = false,
        profile: ReturnInputComposerProfile = .generic
    ) -> [ReturnInputCaptureRegion] {
        guard windowFrame.width > 1, windowFrame.height > 1 else { return [] }
        var result: [ReturnInputCaptureRegion] = []
        let interactionPoints = interactionPoint.map { point in
            [point].filter { candidate in
                distance(windowFrame, to: candidate) <= 4
                    && distance(interactionCoordinateFrame ?? windowFrame, to: candidate) <= 4
                    && profileAccepts(point: candidate, windowFrame: windowFrame, profile: profile)
            }
        } ?? []

        if let focused = clipped(focusedFrame, to: windowFrame),
           profileAcceptsTrustedGeometry(
                frame: focused,
                windowFrame: windowFrame,
                profile: profile
           ) {
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
                var focusedRegion = focused.insetBy(
                    dx: -horizontalPadding,
                    dy: -verticalPadding
                )
                if profile == .codex, focusedRegion.height > 64 {
                    let footerHeight = max(22, min(42, focusedRegion.height * 0.24))
                    focusedRegion.size.height -= footerHeight
                }
                appendRegion(
                    focusedRegion,
                    source: .focusedInput,
                    windowFrame: windowFrame,
                    to: &result
                )
            }
        }

        if let caret = clipped(caretFrame, to: windowFrame),
           profileAcceptsTrustedGeometry(
                frame: caret,
                windowFrame: windowFrame,
                profile: profile
           ) {
            let focused = clipped(focusedFrame, to: windowFrame).flatMap { frame in
                profileAcceptsTrustedGeometry(
                    frame: frame,
                    windowFrame: windowFrame,
                    profile: profile
                ) ? frame : nil
            }
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
            appendRegion(
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
                appendRegion(
                    frame.intersection(profileComposerFrame(windowFrame: windowFrame, profile: profile)),
                    source: .caretNeighborhood,
                    windowFrame: windowFrame,
                    to: &result
                )
            }
        }

        // Last-resort strips are still input-sized crops. They are never the
        // whole window and their OCR is never joined with window-wide OCR.
        if result.isEmpty, allowUnanchoredFallback {
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

    fileprivate static func profileAnchorFrame(
        windowFrame: CGRect,
        profile: ReturnInputComposerProfile
    ) -> CGRect {
        let constraints: (minimumX: CGFloat, minimumY: CGFloat, maximumX: CGFloat)
        switch profile {
        case .generic:
            return windowFrame
        case .weChat:
            constraints = (0.28, 0.67, 0.995)
        case .codex:
            constraints = (0.17, 0.57, 0.995)
        case .feishu:
            constraints = (0.24, 0.61, 0.995)
        }
        return CGRect(
            x: windowFrame.minX + windowFrame.width * constraints.minimumX,
            y: windowFrame.minY + windowFrame.height * constraints.minimumY,
            width: windowFrame.width * (constraints.maximumX - constraints.minimumX),
            height: windowFrame.height * (1 - constraints.minimumY)
        )
    }

    private static func preSubmissionBounds(
        profile: ReturnInputComposerProfile
    ) -> CGRect {
        switch profile {
        case .generic:
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .weChat:
            return CGRect(x: 0.28, y: 0.67, width: 0.715, height: 0.325)
        case .codex:
            // Codex keeps model/usage/screen-sharing status in the very bottom
            // strip. The typing-time ROI is never allowed to include it.
            return CGRect(x: 0.17, y: 0.57, width: 0.825, height: 0.385)
        case .feishu:
            return CGRect(x: 0.24, y: 0.61, width: 0.755, height: 0.385)
        }
    }

    private static func profileComposerFrame(
        windowFrame: CGRect,
        profile: ReturnInputComposerProfile
    ) -> CGRect {
        let constraints: (minimumX: CGFloat, minimumY: CGFloat)
        switch profile {
        case .generic:
            return windowFrame
        case .weChat:
            constraints = (0.26, 0.54)
        case .codex:
            constraints = (0.16, 0.54)
        case .feishu:
            constraints = (0.22, 0.50)
        }
        return CGRect(
            x: windowFrame.minX + windowFrame.width * constraints.minimumX,
            y: windowFrame.minY + windowFrame.height * constraints.minimumY,
            width: windowFrame.width * (1 - constraints.minimumX),
            height: windowFrame.height * (1 - constraints.minimumY)
        )
    }

    private static func profileAccepts(
        frame: CGRect,
        windowFrame: CGRect,
        profile: ReturnInputComposerProfile
    ) -> Bool {
        guard !frame.isNull else { return false }
        if profile == .generic { return true }
        let composer = profileComposerFrame(windowFrame: windowFrame, profile: profile)
        let anchor = CGPoint(x: frame.midX, y: frame.midY)
        return composer.contains(anchor)
            || overlapRatio(frame, with: composer) >= 0.55
    }

    fileprivate static func profileAcceptsTrustedGeometry(
        frame: CGRect,
        windowFrame: CGRect,
        profile: ReturnInputComposerProfile
    ) -> Bool {
        guard !frame.isNull else { return false }
        if profile == .generic { return true }
        let minimumXRatio: CGFloat
        switch profile {
        case .generic:
            minimumXRatio = 0
        case .weChat:
            minimumXRatio = 0.26
        case .codex:
            minimumXRatio = 0.16
        case .feishu:
            minimumXRatio = 0.22
        }
        let mainContent = CGRect(
            x: windowFrame.minX + windowFrame.width * minimumXRatio,
            y: windowFrame.minY,
            width: windowFrame.width * (1 - minimumXRatio),
            height: windowFrame.height
        )
        return mainContent.contains(CGPoint(x: frame.midX, y: frame.midY))
            || overlapRatio(frame, with: mainContent) >= 0.55
    }

    private static func profileAccepts(
        point: CGPoint,
        windowFrame: CGRect,
        profile: ReturnInputComposerProfile
    ) -> Bool {
        profile.acceptsInputAnchor(point, in: windowFrame)
    }

    /// Chooses the crop whose OCR most closely supports the Accessibility
    /// draft. Without a draft, focused/caret crops outrank heuristic strips and
    /// compact input-like OCR outranks large blocks of text.
    public static func selectOCRCandidate(
        _ candidates: [ReturnInputOCRCandidate],
        referenceText: String?
    ) -> ReturnInputOCRCandidate? {
        let reference = cleaned(referenceText)
        let eligible = candidates.filter { candidate in
            guard let reference else { return true }
            guard let text = cleaned(candidate.submittedText)
                    ?? cleaned(candidate.recognizedText) else {
                // An already-cleared, correctly anchored composer remains a
                // safer screenshot than a non-empty crop containing unrelated
                // history or footer status.
                return true
            }
            let referenceKey = comparisonKey(reference)
            let textKey = comparisonKey(text)
            guard referenceKey.count >= 2, textKey.count >= 2 else { return false }
            return referenceKey.contains(textKey)
                || textKey.contains(referenceKey)
                || textSimilarity(reference, text) >= 0.42
        }
        return eligible.max { lhs, rhs in
            score(lhs, referenceText: referenceText) < score(rhs, referenceText: referenceText)
        }
    }

    /// Only ROI OCR belongs in `screenText`; background page Context is already
    /// provided independently by Accessibility and must not pollute submission.
    public static func modelScreenText(from recognizedInputText: String?, limit: Int = 8_000) -> String? {
        guard let rawText = cleaned(recognizedInputText) else { return nil }
        let text = rawText
            .components(separatedBy: .newlines)
            .compactMap(cleaned)
            .filter { !isLikelyInterfaceChrome($0) }
            .joined(separator: "\n")
        guard !text.isEmpty else { return nil }
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

    private static func preSubmissionReferenceScore(
        _ line: NormalizedOCRLine,
        reference: String
    ) -> Double {
        let referenceKey = comparisonKey(reference)
        let lineKey = comparisonKey(line.text)
        guard !referenceKey.isEmpty, !lineKey.isEmpty else { return 0 }
        var score = textSimilarity(reference, line.text) * 100
        if referenceKey.contains(lineKey) || lineKey.contains(referenceKey) {
            score += 60
        }
        score += Double(min(contentCharacterCount(line.text), 120)) * 0.08
        return score
    }

    private static func normalizedHorizontalOverlap(
        _ lhs: NormalizedOCRLine,
        _ rhs: NormalizedOCRLine
    ) -> Double {
        let overlap = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        return overlap / max(0.001, min(lhs.width, rhs.width))
    }

    private static func normalizedVerticalGap(
        _ lhs: NormalizedOCRLine,
        _ rhs: NormalizedOCRLine
    ) -> Double {
        max(rhs.y - (lhs.y + lhs.height), lhs.y - (rhs.y + rhs.height), 0)
    }

    /// Common footer/status labels that can sit within a chat composer's visual
    /// bounds but must never become submitted text. Kept public so the App
    /// adapter and pure OCR tests use one rejection contract.
    public static func isLikelyInterfaceChrome(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = [
            "chatgpt", "codex", "send", "发送", "cancel", "取消", "output", "输出",
            "full access", "完全访问", "sources", "来源", "停止共享", "stop sharing",
            "正在共享屏幕", "你正在共享屏幕", "you are sharing your screen", "screen sharing"
        ]
        if exact.contains(normalized) { return true }
        if normalized.contains("正在共享屏幕")
            || normalized.contains("you are sharing your screen")
            || normalized.contains("screen sharing") {
            return true
        }
        if normalized.range(of: #"^(?:tip|thinking|context|tokens?|model|session|cached|usage|cost)\s*[:：]"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: #"^\d+(?:\.\d+)?\s+(?:sol|tokens?|tok)(?:\s+\S{1,8})?$"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(
            of: #"^\d+(?:\.\d+)?\s*(?:ms|s|sec|secs|second|seconds|秒)(?:\s*[·•|].*)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"^(?:gpt|glm|claude|gemini|kimi|deepseek)[-\s]?[\p{L}\p{N}._-]*(?:\s+(?:auto|high|medium|low))?$"#,
            options: .regularExpression
        ) != nil {
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

    private static func appendRegion(
        _ frame: CGRect,
        source: ReturnInputCaptureSource,
        windowFrame: CGRect,
        to result: inout [ReturnInputCaptureRegion]
    ) {
        guard let clipped = clipped(frame, to: windowFrame) else { return }
        let x = (clipped.minX - windowFrame.minX) / windowFrame.width
        let width = clipped.width / windowFrame.width
        let height = clipped.height / windowFrame.height
        let y = (clipped.minY - windowFrame.minY) / windowFrame.height
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
