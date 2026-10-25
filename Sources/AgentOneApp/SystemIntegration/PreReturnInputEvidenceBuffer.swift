import AgentOneCaptureKit
import AgentOneCore
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// The latest input-sized screenshot observed while a validated typing session
/// was active. It is memory-only: nothing is persisted or sent to a model until
/// Return arrives and the normal sensitive-content gate accepts the OCR.
struct PreReturnInputEvidence: @unchecked Sendable {
    let capturedAt: Date
    let bundleIdentifier: String?
    let windowIdentifier: String?
    let windowFrame: CGRect
    let image: CGImage
    let focusedFrame: CGRect?
    let caretFrame: CGRect?
    let interactionPoint: CGPoint?
    let profile: ReturnInputComposerProfile
    /// The input ROI that was validated while the user was still typing.
    /// Return capture must use this exact spatial hypothesis instead of
    /// running another window-wide locator after the editor has cleared.
    let inputRegion: ReturnInputCaptureRegion
}

/// Keeps one low-rate ScreenCaptureKit stream for the active input session.
/// This avoids racing Return: the event tap stays `.listenOnly`, while the
/// buffer already owns a frame from immediately before the target app clears
/// its editor or moves the text into chat history.
@MainActor
final class PreReturnInputEvidenceBuffer {
    private var frameReceiver: FrameReceiver?
    private var stream: SCStream?
    private var activeKey: String?
    private var activeBundleIdentifier: String?
    private var activeWindowIdentifier: String?
    private var activeWindowFrame: CGRect?
    private var activeFocusedFrame: CGRect?
    private var activeCaretFrame: CGRect?
    private var activeInteractionPoint: CGPoint?
    private var activeProfile: ReturnInputComposerProfile?
    private var activeRegion: ReturnInputCaptureRegion?
    private var minimumFrameTimestamp: Date?
    private var startTask: Task<Void, Never>?
    private var delayedStopTask: Task<Void, Never>?

    func update(
        active: ActiveApplicationContext,
        interactionPoint: CGPoint?,
        profile: ReturnInputComposerProfile,
        signalTimestamp: Date,
        startsNewSubmission: Bool
    ) {
        delayedStopTask?.cancel()
        delayedStopTask = nil
        guard WindowContextCapture.hasScreenRecordingPermission,
              !active.isSecureInput,
              let windowFrame = active.windowFrame else {
            clear()
            return
        }

        let regions = ReturnInputCaptureContract.regions(
            focusedFrame: active.focusedFrame,
            caretFrame: active.focusedCaretFrame,
            windowFrame: windowFrame,
            interactionPoint: interactionPoint,
            profile: profile
        )
        guard let region = preferredRegion(from: regions) else {
            clear()
            return
        }

        let key = [
            active.bundleIdentifier ?? active.applicationName,
            active.windowIdentifier ?? active.windowTitle ?? "window"
        ].joined(separator: "|")
        activeBundleIdentifier = active.bundleIdentifier
        activeWindowIdentifier = active.windowIdentifier
        activeWindowFrame = windowFrame
        activeFocusedFrame = active.focusedFrame
        activeCaretFrame = active.focusedCaretFrame
        activeInteractionPoint = interactionPoint
        activeProfile = profile
        activeRegion = region
        if startsNewSubmission || minimumFrameTimestamp == nil {
            minimumFrameTimestamp = signalTimestamp
        }
        guard key != activeKey else { return }

        stopStream()
        activeKey = key
        startTask = Task { [weak self] in
            await self?.startStream(
                // Bind the stream to the same process that supplied the AX
                // input geometry. Looking up `frontmostApplication` here is a
                // race: the async task may begin after a system panel, Codex,
                // or AgentOne's floating creature has taken focus.
                processIdentifier: active.processIdentifier,
                windowIdentifier: active.windowIdentifier,
                windowTitle: active.windowTitle,
                expectedFrame: windowFrame,
                region: region,
                key: key
            )
        }
    }

    func evidence(
        at timestamp: Date,
        bundleIdentifier: String?,
        windowIdentifier: String?
    ) -> PreReturnInputEvidence? {
        guard let activeKey,
              let windowFrame = activeWindowFrame,
              let activeRegion,
              let profile = activeProfile,
              let minimumFrameTimestamp else {
            return nil
        }
        guard activeBundleIdentifier == nil
                || bundleIdentifier == nil
                || activeBundleIdentifier == bundleIdentifier,
              activeWindowIdentifier == nil
                || windowIdentifier == nil
                || activeWindowIdentifier == windowIdentifier,
              let frame = frameReceiver?.latest(
                for: activeKey,
                atOrBefore: timestamp,
                notBefore: minimumFrameTimestamp
              ),
              frame.timestamp >= minimumFrameTimestamp,
              timestamp.timeIntervalSince(frame.timestamp) >= 0,
              timestamp.timeIntervalSince(frame.timestamp) <= 0.75 else {
            return nil
        }
        return PreReturnInputEvidence(
            capturedAt: frame.timestamp,
            bundleIdentifier: activeBundleIdentifier,
            windowIdentifier: activeWindowIdentifier,
            windowFrame: windowFrame,
            image: frame.image,
            focusedFrame: activeFocusedFrame,
            caretFrame: activeCaretFrame,
            interactionPoint: activeInteractionPoint,
            profile: profile,
            inputRegion: activeRegion
        )
    }

    func clear() {
        delayedStopTask?.cancel()
        delayedStopTask = nil
        activeKey = nil
        activeBundleIdentifier = nil
        activeWindowIdentifier = nil
        activeWindowFrame = nil
        activeFocusedFrame = nil
        activeCaretFrame = nil
        activeInteractionPoint = nil
        activeProfile = nil
        activeRegion = nil
        minimumFrameTimestamp = nil
        frameReceiver?.clear()
        frameReceiver = nil
        stopStream()
    }

    /// Ends the current in-memory capture after Return has taken ownership of
    /// the last frame. A following text key starts a fresh submission stream,
    /// while the runtime's separate session anchor still supports consecutive
    /// messages without another click.
    func finishSubmission() {
        minimumFrameTimestamp = nil
        delayedStopTask?.cancel()
        let key = activeKey
        delayedStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.activeKey == key,
                  self.minimumFrameTimestamp == nil else {
                return
            }
            self.clear()
        }
    }

    private func startStream(
        processIdentifier: pid_t?,
        windowIdentifier: String?,
        windowTitle: String?,
        expectedFrame: CGRect,
        region: ReturnInputCaptureRegion,
        key: String
    ) async {
        guard activeKey == key, let processIdentifier else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                // Feishu reports its visible main window as `isOnScreen ==
                // false` on some macOS/Space combinations. The AX snapshot
                // still gives us an exact PID + title + frame, so include all
                // windows and rank those signals instead of dropping the real
                // composer before matching can happen.
                onScreenWindowsOnly: false
            )
            guard activeKey == key,
                  let window = bestWindow(
                    in: content.windows,
                    processIdentifier: processIdentifier,
                    windowIdentifier: windowIdentifier,
                    windowTitle: windowTitle,
                    expectedFrame: expectedFrame
                  ) else {
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let maximumWidth: CGFloat = 1_600
            let scale = min(1, maximumWidth / max(window.frame.width, 1))
            configuration.width = max(1, Int((window.frame.width * scale).rounded()))
            configuration.height = max(1, Int((window.frame.height * scale).rounded()))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 2
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let receiver = FrameReceiver(key: key)
            try stream.addStreamOutput(
                receiver,
                type: .screen,
                sampleHandlerQueue: receiver.queue
            )
            try await stream.startCapture()
            guard !Task.isCancelled, activeKey == key else {
                try? await stream.stopCapture()
                return
            }
            frameReceiver = receiver
            self.stream = stream

            // The stream captures the whole window. Updating the typing-time
            // ROI must not restart it on every caret movement; a new click or
            // window change clears the buffer, while minimumFrameTimestamp
            // prevents a prior submission's pixels from being reused.
            _ = region
        } catch {
            if activeKey == key {
                frameReceiver?.clear()
            }
        }
    }

    private func stopStream() {
        startTask?.cancel()
        startTask = nil
        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    private func preferredRegion(
        from regions: [ReturnInputCaptureRegion]
    ) -> ReturnInputCaptureRegion? {
        regions.min { lhs, rhs in
            let lhsPriority = sourcePriority(lhs.source)
            let rhsPriority = sourcePriority(rhs.source)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.area < rhs.area
        }
    }

    private func sourcePriority(_ source: ReturnInputCaptureSource) -> Int {
        switch source {
        case .focusedInput: 0
        case .caretNeighborhood: 1
        case .inferredComposerRegion: 2
        }
    }

    private func bestWindow(
        in windows: [SCWindow],
        processIdentifier: pid_t,
        windowIdentifier: String?,
        windowTitle: String?,
        expectedFrame: CGRect
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            window.owningApplication?.processID == processIdentifier
                && window.frame.width >= 180
                && window.frame.height >= 120
        }
        return candidates.max { lhs, rhs in
            windowScore(
                lhs,
                windowIdentifier: windowIdentifier,
                windowTitle: windowTitle,
                expectedFrame: expectedFrame
            ) < windowScore(
                rhs,
                windowIdentifier: windowIdentifier,
                windowTitle: windowTitle,
                expectedFrame: expectedFrame
            )
        }
    }

    private func windowScore(
        _ window: SCWindow,
        windowIdentifier: String?,
        windowTitle: String?,
        expectedFrame: CGRect
    ) -> Double {
        var score = Double(intersectionArea(window.frame, expectedFrame))
        if window.isOnScreen {
            score += 250_000
        }
        if let windowTitle,
           !windowTitle.isEmpty,
           window.title == windowTitle {
            score += 1_000_000
        }
        if let windowIdentifier,
           !windowIdentifier.isEmpty,
           window.title?.contains(windowIdentifier) == true {
            score += 500_000
        }
        return score
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

}

private final class FrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame {
        let timestamp: Date
        let image: CGImage
    }

    let queue = DispatchQueue(label: "life.agentone.pre-return-frame", qos: .userInitiated)
    private let lock = NSLock()
    private let activeKey: String
    /// A short ring is essential here. The latest callback observed after the
    /// Return event may already contain an emptied composer, even though the
    /// stream also delivered a correct frame immediately before Return.
    private var recentFrames: [Frame] = []
    private let maximumFrameCount = 30
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(key: String) {
        activeKey = key
        super.init()
    }

    func latest(
        for key: String,
        atOrBefore timestamp: Date,
        notBefore minimumTimestamp: Date
    ) -> Frame? {
        lock.withLock {
            guard activeKey == key else { return nil }
            guard let index = ReturnSubmissionFrameSelector.latestEligibleIndex(
                in: recentFrames.map(\.timestamp),
                returnTimestamp: timestamp,
                notBefore: minimumTimestamp
            ) else { return nil }
            return recentFrames[index]
        }
    }

    func clear() {
        lock.withLock {
            recentFrames.removeAll(keepingCapacity: false)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let capturedAt = Self.presentationDate(for: sampleBuffer)
        lock.withLock {
            recentFrames.append(Frame(timestamp: capturedAt, image: image))
            if recentFrames.count > maximumFrameCount {
                recentFrames.removeFirst(recentFrames.count - maximumFrameCount)
            }
        }
    }

    /// ScreenCaptureKit may deliver a sample callback after Return even though
    /// the pixels were presented before Return. Convert the sample's host-clock
    /// presentation timestamp to wall time so the selector can distinguish the
    /// actual pre-submit frame from a later cleared-editor frame.
    private static func presentationDate(for sampleBuffer: CMSampleBuffer) -> Date {
        let callbackDate = Date()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard presentationTime.isValid, hostTime.isValid else { return callbackDate }
        let offset = CMTimeGetSeconds(CMTimeSubtract(presentationTime, hostTime))
        guard offset.isFinite, abs(offset) <= 5 else { return callbackDate }
        return callbackDate.addingTimeInterval(offset)
    }
}
