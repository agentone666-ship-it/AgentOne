import Foundation

/// Whether a Return screenshot was observed while the submitted text was
/// still inside the editor, or only after the foreground app handled Return.
///
/// Pre-submission evidence is materially stronger: chat apps commonly clear
/// the editor and move the text into a bubble before an asynchronous screenshot
/// can run, at which point history/sidebar/footer text becomes ambiguous.
public enum ReturnSubmissionEvidencePhase: String, Codable, Sendable {
    case preSubmission = "pre_submission"
    case postSubmission = "post_submission"
}

/// A small pure value used by the runtime to arbitrate independently OCR'd
/// Return captures. Full-window pixels never enter this contract.
public struct ReturnSubmissionEvidenceCandidate: Equatable, Sendable {
    public let id: Int
    public let phase: ReturnSubmissionEvidencePhase
    public let recognizedText: String?
    public let submittedText: String?

    public init(
        id: Int,
        phase: ReturnSubmissionEvidencePhase,
        recognizedText: String?,
        submittedText: String?
    ) {
        self.id = id
        self.phase = phase
        self.recognizedText = recognizedText
        self.submittedText = submittedText
    }
}

/// Chooses the strongest proof of what the user submitted.
///
/// A meaningful pre-Return editor crop always wins over an equally supported
/// post-Return crop. When Accessibility supplied a draft, every eligible OCR
/// candidate must support that draft; unrelated history or status text is not
/// allowed to become submitted content merely because the real editor cleared.
public enum ReturnSubmissionEvidenceSelector {
    public static func select(
        _ candidates: [ReturnSubmissionEvidenceCandidate],
        referenceText: String?
    ) -> ReturnSubmissionEvidenceCandidate? {
        let reference = cleaned(referenceText)
        let eligible = candidates.compactMap { candidate -> (ReturnSubmissionEvidenceCandidate, String)? in
            guard let text = cleaned(candidate.submittedText)
                    ?? cleaned(candidate.recognizedText),
                  contentCharacterCount(text) >= 2 else {
                return nil
            }
            if let reference, !supports(reference: reference, evidence: text) {
                return nil
            }
            return (candidate, text)
        }

        return eligible.max { lhs, rhs in
            score(lhs, reference: reference) < score(rhs, reference: reference)
        }?.0
    }

    public static func supportsReference(
        evidenceText: String?,
        referenceText: String?
    ) -> Bool {
        guard let evidence = cleaned(evidenceText) else { return false }
        guard let reference = cleaned(referenceText) else {
            return contentCharacterCount(evidence) >= 2
        }
        return supports(reference: reference, evidence: evidence)
    }

    /// Applies the stricter contract used for a frame frozen before Return.
    /// Without an AX draft, a status/footer label is not enough evidence: the
    /// ROI must contain at least three real content characters after every UI
    /// chrome line has been removed. With a draft, the OCR must also support it.
    public static func supportsPreSubmissionEvidence(
        evidenceText: String?,
        referenceText: String?
    ) -> Bool {
        let meaningful = cleanedMeaningfulLines(evidenceText)
        guard !meaningful.isEmpty else { return false }
        let evidence = meaningful.joined(separator: "\n")
        guard contentCharacterCount(evidence) >= 3 else { return false }
        guard let reference = cleaned(referenceText) else { return true }
        return supports(reference: reference, evidence: evidence)
    }

    private static func score(
        _ value: (ReturnSubmissionEvidenceCandidate, String),
        reference: String?
    ) -> Double {
        let phaseScore = value.0.phase == .preSubmission ? 1_000.0 : 0
        guard let reference else {
            return phaseScore + Double(min(contentCharacterCount(value.1), 200))
        }
        return phaseScore + similarity(reference, value.1) * 300
    }

    private static func supports(reference: String, evidence: String) -> Bool {
        let referenceKey = comparisonKey(reference)
        let evidenceKey = comparisonKey(evidence)
        guard referenceKey.count >= 2, evidenceKey.count >= 2 else { return false }
        if referenceKey.contains(evidenceKey) || evidenceKey.contains(referenceKey) {
            let balance = Double(min(referenceKey.count, evidenceKey.count))
                / Double(max(referenceKey.count, evidenceKey.count))
            return balance >= 0.45
        }
        return similarity(reference, evidence) >= 0.72
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(comparisonKey(lhs))
        let right = Array(comparisonKey(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let longest = max(left.count, right.count)
        let shortest = min(left.count, right.count)
        guard Double(shortest) / Double(longest) >= 0.40 else { return 0 }
        let distance = levenshteinDistance(left, right)
        return max(0, 1 - Double(distance) / Double(longest))
    }

    private static func levenshteinDistance(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Int {
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

    private static func cleanedMeaningfulLines(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .components(separatedBy: .newlines)
            .compactMap(cleaned)
            .filter { !ReturnInputCaptureContract.isLikelyInterfaceChrome($0) }
    }
}

/// Selects the frame that was actually presented immediately before Return.
/// Stream callbacks can arrive after the key event, so delivery order alone is
/// insufficient: a callback received later may already show a cleared editor.
public enum ReturnSubmissionFrameSelector {
    public static func latestEligibleIndex(
        in timestamps: [Date],
        returnTimestamp: Date,
        notBefore minimumTimestamp: Date,
        maximumAge: TimeInterval = 0.75
    ) -> Int? {
        timestamps.indices
            .filter { index in
                let timestamp = timestamps[index]
                return timestamp >= minimumTimestamp
                    && timestamp <= returnTimestamp
                    && returnTimestamp.timeIntervalSince(timestamp) <= maximumAge
            }
            .max { lhs, rhs in
                timestamps[lhs] < timestamps[rhs]
            }
    }
}
