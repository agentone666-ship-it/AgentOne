import Foundation

/// Reconciles the Accessibility value sampled while an IME is composing with
/// the text visible in the key screenshot. Some web editors expose unfinished
/// pinyin (for example, `pao ton`) even though the committed Chinese glyphs are
/// already visible on screen. The screenshot remains the evidence of record;
/// this helper only selects a closely matching visible line.
public enum SubmittedTextReconciler {
    public static func reconcile(
        draftText: String?,
        screenText: String?
    ) -> String? {
        guard let draft = cleaned(draftText), draft.count >= 2 else { return nil }
        guard let screenText, !screenText.isEmpty else { return draft }

        let draftKey = comparisonKey(draft)
        guard draftKey.count >= 2 else { return draft }

        let lines = screenText
            .components(separatedBy: .newlines)
            .compactMap(cleaned)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return draft }

        var candidates = lines
        if lines.count > 1 {
            for index in lines.indices {
                if index + 1 < lines.count {
                    candidates.append("\(lines[index]) \(lines[index + 1])")
                }
                if index + 2 < lines.count {
                    candidates.append("\(lines[index]) \(lines[index + 1]) \(lines[index + 2])")
                }
            }
        }

        let maximumCandidateLength = max(80, draft.count * 2 + 24)
        let draftASCII = asciiLetterCount(in: draftKey)
        let draftCJK = cjkCount(in: draftKey)
        let attachedLowercaseASCIITail = attachedLowercaseASCIITailLength(in: draft)
        let attachedLowercaseIMEComposition = attachedLowercaseIMECompositionLetterCount(in: draft)
        var best: (text: String, score: Double, similarity: Double, imeCorrection: Bool)?

        for candidate in candidates where candidate.count <= maximumCandidateLength {
            let candidateKey = comparisonKey(candidate)
            guard candidateKey.count >= 2 else { continue }
            if candidateKey == draftKey {
                return draft
            }

            let longest = max(draftKey.count, candidateKey.count)
            let shortest = min(draftKey.count, candidateKey.count)
            guard longest > 0, Double(shortest) / Double(longest) >= 0.45 else { continue }

            let distance = levenshteinDistance(draftKey, candidateKey)
            let similarity = 1 - Double(distance) / Double(longest)
            let prefix = Double(commonPrefixLength(draftKey, candidateKey)) / Double(shortest)
            let lengthBalance = Double(shortest) / Double(longest)
            let candidateASCII = asciiLetterCount(in: candidateKey)
            let candidateCJK = cjkCount(in: candidateKey)
            let sharedPrefixLength = commonPrefixLength(draftKey, candidateKey)
            let looksLikeLongIMECompletion = attachedLowercaseIMEComposition >= 3
                && draftASCII >= 3
                && candidateASCII + 2 <= draftASCII
                && candidateCJK >= draftCJK
                && prefix >= 0.4
            let draftBaseLength = draftKey.count - attachedLowercaseASCIITail
            let candidateSuffix = draftBaseLength <= candidateKey.count
                ? Array(candidateKey.dropFirst(draftBaseLength))
                : []
            let looksLikeShortIMECompletion = (1...8).contains(attachedLowercaseASCIITail)
                && draftCJK >= 4
                && draftBaseLength >= 4
                && sharedPrefixLength >= draftBaseLength
                && (1...16).contains(candidateSuffix.count)
                && cjkCount(in: candidateSuffix) >= 1
                && asciiLetterCount(in: candidateSuffix) == 0
                && candidateCJK > draftCJK
            let looksLikeIMECompletion = looksLikeLongIMECompletion
                || looksLikeShortIMECompletion

            var score = similarity * 0.65 + prefix * 0.2 + lengthBalance * 0.15
            if looksLikeLongIMECompletion { score += 0.12 }
            if looksLikeShortIMECompletion { score += 0.18 }
            if draftKey.contains(candidateKey) || candidateKey.contains(draftKey) { score += 0.08 }

            if best == nil || score > best!.score {
                best = (candidate, score, similarity, looksLikeIMECompletion)
            }
        }

        guard let best else { return draft }
        if best.imeCorrection, best.score >= 0.64 {
            return best.text
        }
        if best.similarity >= 0.86, best.score >= 0.82 {
            return best.text
        }
        return draft
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func comparisonKey(_ value: String) -> [Character] {
        Array(value.lowercased().filter { character in
            character.isLetter || character.isNumber
        })
    }

    private static func asciiLetterCount(in value: [Character]) -> Int {
        value.reduce(into: 0) { count, character in
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  (65...90).contains(Int(scalar.value))
                    || (97...122).contains(Int(scalar.value)) else {
                return
            }
            count += 1
        }
    }

    /// Returns a short lowercase ASCII tail only when it is directly attached
    /// to a CJK character. This is the shape exposed by macOS Accessibility
    /// when Return races an active Chinese IME composition, for example
    /// `特别是s`. A separated English token such as `支持 GPT` is deliberately
    /// excluded so screenshot OCR cannot casually replace real English text.
    private static func attachedLowercaseASCIITailLength(in value: String) -> Int {
        let characters = Array(value)
        guard !characters.isEmpty else { return 0 }

        var tailLength = 0
        var index = characters.count
        while index > 0, isLowercaseASCIILetter(characters[index - 1]) {
            tailLength += 1
            index -= 1
        }
        guard (1...8).contains(tailLength), index > 0,
              isCJK(characters[index - 1]) else {
            return 0
        }
        return tailLength
    }

    /// Recognizes an unfinished lowercase pinyin composition attached directly
    /// to Chinese text, while allowing separators inside the pinyin itself
    /// (`能不能pao ton`). Uppercase or whitespace-separated English tokens are
    /// intentionally rejected.
    private static func attachedLowercaseIMECompositionLetterCount(in value: String) -> Int {
        let characters = Array(value)
        guard let last = characters.last, isLowercaseASCIILetter(last) else { return 0 }

        var letterCount = 0
        var index = characters.count
        while index > 0 {
            let character = characters[index - 1]
            if isLowercaseASCIILetter(character) {
                letterCount += 1
                index -= 1
                continue
            }
            if character == " " || character == "'" || character == "’" {
                index -= 1
                continue
            }
            break
        }

        guard (1...24).contains(letterCount), index > 0, index < characters.count,
              isCJK(characters[index - 1]),
              isLowercaseASCIILetter(characters[index]) else {
            return 0
        }
        return letterCount
    }

    private static func isLowercaseASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return (97...122).contains(Int(scalar.value))
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func cjkCount(in value: [Character]) -> Int {
        value.reduce(into: 0) { count, character in
            guard isCJK(character) else {
                return
            }
            count += 1
        }
    }

    private static func commonPrefixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var count = 0
        for pair in zip(lhs, rhs) {
            guard pair.0 == pair.1 else { break }
            count += 1
        }
        return count
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                current[rhsIndex + 1] = min(
                    current[rhsIndex] + 1,
                    previous[rhsIndex + 1] + 1,
                    previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
