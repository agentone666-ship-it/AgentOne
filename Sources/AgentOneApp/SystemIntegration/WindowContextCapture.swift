import AppKit
import AgentOneCore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import Vision

enum WindowContextCaptureError: Error {
    case permissionDenied
    case noFrontmostApplication
    case noShareableWindow
    case noInputRegion
    case pngEncodingFailed
}

struct CapturedKeyMoment: Sendable {
    let pngData: Data
    let recognizedText: String?
    let submittedTextCandidate: String?
    let recognizedLineCount: Int
    let fullScreenOCRLineCount: Int
    let source: ReturnInputCaptureSource
    let cropPixelWidth: Int
    let cropPixelHeight: Int
    let windowTitle: String?
}

/// Captures one user-authorized key screenshot. It never records video and
/// never writes to disk until the caller has run the OCR text through the
/// sensitive-content gate.
@MainActor
enum WindowContextCapture {
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func captureFrontmostWindow(
        focusedFrame: CGRect? = nil,
        caretFrame: CGRect? = nil,
        referenceText: String? = nil,
        interactionPoint: CGPoint? = nil
    ) async throws -> CapturedKeyMoment {
        guard hasScreenRecordingPermission else {
            throw WindowContextCaptureError.permissionDenied
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw WindowContextCaptureError.noFrontmostApplication
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == application.processIdentifier
                && window.isOnScreen
                && window.frame.width >= 180
                && window.frame.height >= 120
        }
        guard let window = bestWindow(
            from: candidates,
            focusedFrame: focusedFrame,
            caretFrame: caretFrame,
            interactionPoint: interactionPoint
        ) else {
            throw WindowContextCaptureError.noShareableWindow
        }

        // Return capture intentionally starts with a single full-display
        // screenshot. It is an in-memory locator pass only: we OCR the entire
        // display to find the actual composer line, then discard the full
        // image before persisting or sending anything to a model.
        let display = content.displays
            .filter { $0.frame.intersects(window.frame) }
            .max(by: {
                intersectionArea($0.frame, window.frame)
                    < intersectionArea($1.frame, window.frame)
            })
            ?? content.displays.first
        let fullScreenImage: CGImage?
        let fullScreenLines: [NormalizedOCRLine]
        if let display {
            let capturedDisplay = try await captureDisplay(display)
            fullScreenImage = capturedDisplay
            fullScreenLines = recognizeTextLines(in: capturedDisplay)
        } else {
            fullScreenImage = nil
            fullScreenLines = []
        }

        // Crop from the exact full-display frame used by the locator. Taking a
        // second window screenshot here creates a race: Return may clear the
        // composer or move the submitted text into chat history between the two
        // captures. A single immutable frame guarantees that location OCR and
        // input-region OCR observe the same UI state.
        let image: CGImage
        if let display,
           let fullScreenImage,
           display.frame.contains(window.frame),
           let windowCrop = crop(
                fullScreenImage,
                displayFrame: display.frame,
                windowFrame: window.frame
           ) {
            image = windowCrop
        } else {
            image = try await captureWindow(window)
        }
        let visionRegions = display.map { display in
            ReturnInputCaptureContract.regionsFromFullScreenOCR(
                lines: fullScreenLines,
                focusedFrame: focusedFrame,
                caretFrame: caretFrame,
                windowFrame: window.frame,
                displayFrame: display.frame,
                referenceText: referenceText,
                interactionPoint: interactionPoint
            )
        } ?? []
        let axRegions = ReturnInputCaptureContract.regions(
            focusedFrame: focusedFrame,
            caretFrame: caretFrame,
            windowFrame: window.frame,
            interactionPoint: interactionPoint,
            interactionCoordinateFrame: display?.frame
        )
        // Vision-derived regions lead the candidate list, while AX/caret
        // regions remain as a reliable fallback for an empty or already-cleared
        // composer. All candidates are still cropped and OCR'd independently.
        let regions = visionRegions + axRegions
        var cropCandidates: [CropCandidate] = []
        for (index, region) in regions.enumerated() {
            guard let crop = crop(image, to: region) else { continue }
            let lines = recognizeTextLines(in: crop)
            let recognizedText = ScreenshotTextExtraction.fullText(from: lines, limit: 6_000)
            let inferredSubmittedText = ScreenshotTextExtraction.inferredSubmittedText(from: lines)
            let submittedText = ScreenshotTextExtraction.preferredSubmittedText(
                focusedRegionText: recognizedText,
                inferredSubmittedText: inferredSubmittedText
            )
            let confidence = lines.isEmpty
                ? 0
                : lines.reduce(0) { $0 + $1.confidence } / Double(lines.count)
            cropCandidates.append(
                CropCandidate(
                    image: crop,
                    metadata: ReturnInputOCRCandidate(
                        id: index,
                        source: region.source,
                        recognizedText: recognizedText,
                        submittedText: submittedText,
                        recognizedLineCount: lines.count,
                        averageConfidence: confidence
                    )
                )
            )
        }

        guard let selectedMetadata = ReturnInputCaptureContract.selectOCRCandidate(
            cropCandidates.map(\.metadata),
            referenceText: referenceText
        ),
        let selected = cropCandidates.first(where: { $0.metadata.id == selectedMetadata.id }) else {
            throw WindowContextCaptureError.noInputRegion
        }
        let bitmap = NSBitmapImageRep(cgImage: selected.image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw WindowContextCaptureError.pngEncodingFailed
        }
        return CapturedKeyMoment(
            pngData: pngData,
            recognizedText: selectedMetadata.recognizedText,
            submittedTextCandidate: selectedMetadata.submittedText,
            recognizedLineCount: selectedMetadata.recognizedLineCount,
            fullScreenOCRLineCount: fullScreenLines.count,
            source: selectedMetadata.source,
            cropPixelWidth: selected.image.width,
            cropPixelHeight: selected.image.height,
            windowTitle: window.title
        )
    }

    static func persist(
        _ capture: CapturedKeyMoment,
        under rootURL: URL,
        at timestamp: Date
    ) throws -> String {
        let day = dayFormatter.string(from: timestamp)
        let directory = rootURL
            .appendingPathComponent("Evidence", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = "\(fileTimestampFormatter.string(from: timestamp))-\(UUID().uuidString.lowercased()).png"
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        try capture.pngData.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL.path
    }

    private static func recognizeTextLines(in image: CGImage) -> [NormalizedOCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return NormalizedOCRLine(
                text: text,
                x: box.minX,
                y: box.minY,
                width: box.width,
                height: box.height,
                confidence: Double(candidate.confidence)
            )
        }
    }

    private static func captureDisplay(_ display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let maximumWidth: CGFloat = 2_400
        let scale = min(1, maximumWidth / max(display.frame.width, 1))
        configuration.width = max(1, Int((display.frame.width * scale).rounded()))
        configuration.height = max(1, Int((display.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let maximumWidth: CGFloat = 1_800
        let scale = min(1, maximumWidth / max(window.frame.width, 1))
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private static func bestWindow(
        from candidates: [SCWindow],
        focusedFrame: CGRect?,
        caretFrame: CGRect?,
        interactionPoint: CGPoint?
    ) -> SCWindow? {
        let target = caretFrame ?? focusedFrame
        if let target {
            let targetPoint = CGPoint(x: target.midX, y: target.midY)
            let matching = candidates.filter { window in
                window.frame.contains(targetPoint)
                    || window.frame.intersects(target)
            }
            if let best = matching.max(by: {
                intersectionArea($0.frame, target) < intersectionArea($1.frame, target)
            }) {
                return best
            }
        }
        if let interactionPoint,
           let best = candidates
            .filter({ $0.frame.contains(interactionPoint) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return best
        }
        return candidates.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        })
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func crop(
        _ image: CGImage,
        to region: ReturnInputCaptureRegion
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let raw = CGRect(
            x: region.x * Double(image.width),
            y: region.y * Double(image.height),
            width: region.width * Double(image.width),
            height: region.height * Double(image.height)
        ).integral
        let clipped = raw.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 24, clipped.height >= 18 else { return nil }
        return image.cropping(to: clipped)
    }

    private static func crop(
        _ displayImage: CGImage,
        displayFrame: CGRect,
        windowFrame: CGRect
    ) -> CGImage? {
        guard displayFrame.width > 1,
              displayFrame.height > 1,
              displayFrame.contains(windowFrame) else {
            return nil
        }
        let scaleX = CGFloat(displayImage.width) / displayFrame.width
        let scaleY = CGFloat(displayImage.height) / displayFrame.height
        let raw = CGRect(
            x: (windowFrame.minX - displayFrame.minX) * scaleX,
            y: (windowFrame.minY - displayFrame.minY) * scaleY,
            width: windowFrame.width * scaleX,
            height: windowFrame.height * scaleY
        ).integral
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: displayImage.width,
            height: displayImage.height
        )
        let clipped = raw.intersection(imageBounds)
        guard !clipped.isNull,
              clipped.width >= 180,
              clipped.height >= 120 else {
            return nil
        }
        return displayImage.cropping(to: clipped)
    }

    private struct CropCandidate {
        let image: CGImage
        let metadata: ReturnInputOCRCandidate
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HHmmss-SSS"
        return formatter
    }()
}
