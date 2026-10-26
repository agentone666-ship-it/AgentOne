import AgentOneCaptureKit
import AgentOneCore
import AppKit
@preconcurrency import ScreenCaptureKit
import Testing
@testable import AgentOneApp

@Suite(.serialized)
@MainActor
struct WindowContextCaptureIntegrationTests {
    private let width = 1_200
    private let height = 800
    private var windowFrame: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    @Test
    func codexFrozenROIUsesRealVisionOCRAndRejectsSharingFooter() throws {
        let image = makeWindowImage(lines: [
            ("Codex second message", 330, 615, 34),
            ("你正在共享屏幕", 330, 742, 25),
            ("GPT-5 Auto", 890, 742, 22),
            ("5.6 S", 1_040, 742, 22)
        ])
        let frozen = ReturnInputCaptureRegion(
            x: 0.20,
            y: 0.70,
            width: 0.72,
            height: 0.25,
            source: .focusedInput
        )

        let capture = try WindowContextCapture.captureBufferedInputRegion(
            image,
            windowFrame: windowFrame,
            region: frozen,
            referenceText: "Codex second message",
            profile: .codex
        )

        #expect(capture.recognizedText?.contains("Codex second message") == true)
        #expect(capture.recognizedText?.contains("共享屏幕") != true)
        #expect(capture.recognizedText?.contains("GPT-5") != true)
        #expect(capture.recognizedText?.contains("5.6") != true)
        #expect(capture.fullScreenOCRLineCount == 0)
        #expect(capture.visionRegions.isEmpty)
        #expect(capture.selectedRegion.maxY <= frozen.maxY)
        #expect(capture.cropPixelHeight < Int(Double(height) * frozen.height))
    }

    @Test
    func weChatConsecutiveReturnsKeepSameROIAndOnlyCaptureCurrentText() throws {
        let frozen = ReturnInputCaptureRegion(
            x: 0.30,
            y: 0.68,
            width: 0.64,
            height: 0.27,
            source: .caretNeighborhood
        )
        let second = makeWindowImage(lines: [
            ("WeChat first message", 410, 565, 29),
            ("WeChat second message", 410, 682, 32)
        ])
        let third = makeWindowImage(lines: [
            ("WeChat second message", 410, 565, 29),
            ("WeChat third message", 410, 682, 32)
        ])

        let secondCapture = try WindowContextCapture.captureBufferedInputRegion(
            second,
            windowFrame: windowFrame,
            region: frozen,
            referenceText: "WeChat second message",
            profile: .weChat
        )
        let thirdCapture = try WindowContextCapture.captureBufferedInputRegion(
            third,
            windowFrame: windowFrame,
            region: frozen,
            referenceText: "WeChat third message",
            profile: .weChat
        )

        #expect(secondCapture.recognizedText?.contains("WeChat second message") == true)
        #expect(secondCapture.recognizedText?.contains("first") != true)
        #expect(thirdCapture.recognizedText?.contains("WeChat third message") == true)
        #expect(thirdCapture.recognizedText?.contains("second") != true)
        #expect(secondCapture.axRegions == thirdCapture.axRegions)
        #expect(secondCapture.selectedRegion.x >= frozen.x)
        #expect(thirdCapture.selectedRegion.x >= frozen.x)
    }

    @Test
    func feishuWithoutAXDraftUsesLowestMeaningfulComposerBlock() throws {
        let image = makeWindowImage(lines: [
            ("Feishu old message", 380, 530, 29),
            ("Feishu third message", 380, 690, 34),
            ("发送", 1_030, 752, 24)
        ])
        let frozen = ReturnInputCaptureRegion(
            x: 0.26,
            y: 0.62,
            width: 0.70,
            height: 0.34,
            source: .caretNeighborhood
        )

        let capture = try WindowContextCapture.captureBufferedInputRegion(
            image,
            windowFrame: windowFrame,
            region: frozen,
            referenceText: nil,
            profile: .feishu
        )

        #expect(capture.recognizedText?.contains("Feishu third message") == true)
        #expect(capture.recognizedText?.contains("old") != true)
        #expect(capture.recognizedText?.contains("发送") != true)
        #expect(capture.submittedTextCandidate?.contains("Feishu third message") == true)
    }

    @Test
    func chromeOnlyFrozenROIFailsClosedInsteadOfPersistingWrongCrop() throws {
        let image = makeWindowImage(lines: [
            ("你正在共享屏幕", 330, 690, 28),
            ("GPT-5 Auto", 880, 742, 22),
            ("5.6 S", 1_040, 742, 22)
        ])

        do {
            let capture = try WindowContextCapture.captureBufferedInputRegion(
                image,
                windowFrame: windowFrame,
                region: ReturnInputCaptureRegion(
                    x: 0.20,
                    y: 0.70,
                    width: 0.72,
                    height: 0.25,
                    source: .focusedInput
                ),
                referenceText: nil,
                profile: .codex
            )
            print("chrome-only OCR:", capture.recognizedText ?? "nil")
            Issue.record("Chrome-only frozen ROI was accepted: \(capture.recognizedText ?? "nil")")
        } catch is WindowContextCaptureError {
            // Expected: no meaningful pre-submission content exists.
        }
    }

    /// Opt-in production-path probe for a real foreground composer. This is
    /// intentionally disabled during normal test runs because it depends on a
    /// user-authorized macOS Accessibility + Screen Recording session and on
    /// the requested app already containing the expected unsent draft.
    ///
    /// Example:
    /// AGENTONE_LIVE_RETURN_APP=com.bytedance.macos.feishu \
    /// AGENTONE_LIVE_RETURN_TEXT='AGENTONE FEISHU PRE RETURN 20260812 01' \
    /// swift test --filter liveForegroundComposerFreezesAndOCRsCurrentDraft
    @Test
    func liveForegroundComposerFreezesAndOCRsCurrentDraft() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let expectedBundle = environment["AGENTONE_LIVE_RETURN_APP"],
              let expectedText = environment["AGENTONE_LIVE_RETURN_TEXT"] else {
            return
        }

        let targetApplication = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: expectedBundle
            ).first
        )
        // Do not rely on `NSWorkspace.frontmostApplication` here. Test runners,
        // loginwindow and AgentOne's floating panel can all win that race even
        // while the requested app remains visible and has a valid composer.
        _ = targetApplication.activate()
        try await Task.sleep(for: .milliseconds(500))

        let active = try #require(ActiveContextReader.read(
            application: targetApplication,
            scope: .focusedElement
        ))
        try #require(active.bundleIdentifier == expectedBundle)
        #expect(active.processIdentifier == targetApplication.processIdentifier)
        #expect(active.isSecureInput == false)
        if let focusedText = active.focusedText {
            #expect(
                ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
                    evidenceText: focusedText,
                    referenceText: expectedText
                )
            )
        }

        print("live target pid:", targetApplication.processIdentifier)
        print("live activation state:", targetApplication.isActive)
        print("live screen recording permission:", WindowContextCapture.hasScreenRecordingPermission)
        print("live foreground bundle:", active.bundleIdentifier ?? "nil")
        print("live window title:", active.windowTitle ?? "nil")
        print("live window id:", active.windowIdentifier ?? "nil")
        print("live window frame:", String(describing: active.windowFrame))
        print("live focused role:", active.focusedRole ?? "nil")
        print("live focused frame:", String(describing: active.focusedFrame))
        print("live caret frame:", String(describing: active.focusedCaretFrame))
        print("live focused text:", active.focusedText ?? "nil")

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let candidateWindows = shareableContent.windows.filter {
            $0.owningApplication?.processID == targetApplication.processIdentifier
        }
        print("live candidate windows:", candidateWindows.map {
            [
                "id=\($0.windowID)",
                "title=\($0.title ?? "nil")",
                "onScreen=\($0.isOnScreen)",
                "frame=\($0.frame)"
            ].joined(separator: " ")
        })

        let profile = ReturnInputComposerProfile.resolve(
            bundleIdentifier: active.bundleIdentifier,
            applicationName: active.applicationName
        )
        let buffer = PreReturnInputEvidenceBuffer()
        defer { buffer.clear() }
        let startedAt = Date()
        buffer.update(
            active: active,
            interactionPoint: active.focusedCaretFrame.map {
                CGPoint(x: $0.midX, y: $0.midY)
            } ?? active.focusedFrame.map {
                CGPoint(x: $0.midX, y: $0.midY)
            },
            profile: profile,
            signalTimestamp: startedAt,
            startsNewSubmission: true
        )

        var evidence: PreReturnInputEvidence?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let sampledAt = Date()
            evidence = buffer.evidence(
                at: sampledAt,
                bundleIdentifier: active.bundleIdentifier,
                windowIdentifier: active.windowIdentifier
            )
            if evidence != nil { break }
        }

        let frozen = try #require(evidence)
        let capture = try WindowContextCapture.captureBufferedInputRegion(
            frozen.image,
            windowFrame: frozen.windowFrame,
            region: frozen.inputRegion,
            referenceText: expectedText,
            profile: frozen.profile
        )

        #expect(capture.fullScreenOCRLineCount == 0)
        #expect(capture.visionRegions.isEmpty)
        #expect(capture.selectedRegion.x >= frozen.inputRegion.x)
        #expect(capture.selectedRegion.y >= frozen.inputRegion.y)
        #expect(capture.selectedRegion.maxX <= frozen.inputRegion.maxX)
        #expect(capture.selectedRegion.maxY <= frozen.inputRegion.maxY)
        #expect(
            ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
                evidenceText: capture.submittedTextCandidate ?? capture.recognizedText,
                referenceText: expectedText
            )
        )

        print("live frozen ROI:", frozen.inputRegion)
        print("live selected ROI:", capture.selectedRegion)
        print("live OCR:", capture.recognizedText ?? "nil")
    }

    private func makeWindowImage(
        lines: [(text: String, x: CGFloat, top: CGFloat, size: CGFloat)]
    ) -> CGImage {
        let cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for line in lines {
            let font = NSFont.systemFont(ofSize: line.size, weight: .regular)
            NSString(string: line.text).draw(
                at: NSPoint(
                    x: line.x,
                    y: CGFloat(height) - line.top - line.size * 1.25
                ),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.black
                ]
            )
        }

        NSGraphicsContext.restoreGraphicsState()
        return cgContext.makeImage()!
    }
}
