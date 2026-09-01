import AgentOneCore
import CoreGraphics
import Foundation

/// Append-only metadata for diagnosing Return capture geometry. This ledger
/// deliberately contains no OCR text, submitted text, window contents or
/// screenshots, and is never included in a model prompt.
actor ReturnCaptureDiagnosticStore {
    struct Record: Encodable, Sendable {
        let timestamp: Date
        let profile: String
        let bundleIdentifier: String?
        let focusedRole: String?
        let focusedFrame: RectSnapshot?
        let caretFrame: RectSnapshot?
        let interactionPoint: PointSnapshot?
        let anchorSource: String?
        let evidencePhase: String?
        let windowFrame: RectSnapshot?
        let visionRegions: [RegionSnapshot]
        let axRegions: [RegionSnapshot]
        let selectedRegion: RegionSnapshot?
        let selectedSource: String?
        let fullScreenOCRLineCount: Int
        let recognizedLineCount: Int
        let cropPixelWidth: Int
        let cropPixelHeight: Int
        let submittedTextPresent: Bool
        let failureReason: String?

        init(
            timestamp: Date,
            profile: ReturnInputComposerProfile,
            bundleIdentifier: String?,
            focusedRole: String?,
            focusedFrame: CGRect?,
            caretFrame: CGRect?,
            interactionPoint: CGPoint?,
            anchorSource: String?,
            evidencePhase: String? = nil,
            metadata: ReturnCaptureAttemptMetadata?,
            submittedTextPresent: Bool,
            failureReason: String?
        ) {
            self.timestamp = timestamp
            self.profile = profile.rawValue
            self.bundleIdentifier = bundleIdentifier
            self.focusedRole = focusedRole
            self.focusedFrame = focusedFrame.map(RectSnapshot.init)
            self.caretFrame = caretFrame.map(RectSnapshot.init)
            self.interactionPoint = interactionPoint.map(PointSnapshot.init)
            self.anchorSource = anchorSource
            self.evidencePhase = evidencePhase
            self.windowFrame = metadata.map { RectSnapshot($0.windowFrame) }
            self.visionRegions = metadata?.visionRegions.map(RegionSnapshot.init) ?? []
            self.axRegions = metadata?.axRegions.map(RegionSnapshot.init) ?? []
            self.selectedRegion = metadata?.selectedRegion.map(RegionSnapshot.init)
            self.selectedSource = metadata?.selectedSource?.rawValue
            self.fullScreenOCRLineCount = metadata?.fullScreenOCRLineCount ?? 0
            self.recognizedLineCount = metadata?.recognizedLineCount ?? 0
            self.cropPixelWidth = metadata?.cropPixelWidth ?? 0
            self.cropPixelHeight = metadata?.cropPixelHeight ?? 0
            self.submittedTextPresent = submittedTextPresent
            self.failureReason = failureReason
        }
    }

    struct RectSnapshot: Encodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    struct PointSnapshot: Encodable, Sendable {
        let x: Double
        let y: Double

        init(_ point: CGPoint) {
            x = point.x
            y = point.y
        }
    }

    struct RegionSnapshot: Encodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let source: String

        init(_ region: ReturnInputCaptureRegion) {
            x = region.x
            y = region.y
            width = region.width
            height = region.height
            source = region.source.rawValue
        }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder

    init(rootURL: URL) {
        let directory = rootURL.appendingPathComponent("Diagnostics", isDirectory: true)
        fileURL = directory.appendingPathComponent("return-capture.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func append(_ record: Record) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var line = try encoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

extension CapturedKeyMoment {
    var diagnosticMetadata: ReturnCaptureAttemptMetadata {
        ReturnCaptureAttemptMetadata(
            windowFrame: windowFrame,
            visionRegions: visionRegions,
            axRegions: axRegions,
            selectedRegion: selectedRegion,
            selectedSource: source,
            fullScreenOCRLineCount: fullScreenOCRLineCount,
            recognizedLineCount: recognizedLineCount,
            cropPixelWidth: cropPixelWidth,
            cropPixelHeight: cropPixelHeight
        )
    }
}
