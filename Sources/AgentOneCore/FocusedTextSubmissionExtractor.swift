import Foundation

/// Extracts the text that the user is about to submit from the focused
/// Accessibility value. Some terminal-style apps expose their entire scrollback
/// buffer as one AXTextArea, so treating the whole value as a submission turns
/// a single Return event into thousands of characters of unrelated Context.
///
/// The selection range is expressed in UTF-16 offsets, matching
/// `kAXSelectedTextRangeAttribute` and `NSString`.
public enum FocusedTextSubmissionExtractor {
    public static func extract(
        focusedText: String?,
        selectionRange: Range<Int>?,
        applicationName: String?,
        bundleIdentifier: String?,
        focusedRole: String?,
        limit: Int = 2_000
    ) -> String? {
        guard limit > 0, let focusedText else { return nil }
        let text = normalizedMultiline(focusedText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let terminal = isTerminalLike(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        let lines = text.components(separatedBy: .newlines)
        let compactComposer = !terminal
            && text.utf16.count <= 1_500
            && lines.count <= 8
            && isDirectTextInputRole(focusedRole)

        if compactComposer {
            return plausibleSubmission(text, limit: limit)
        }

        // Large document/terminal values are unsafe without a caret. Returning
        // nil intentionally hands control to screenshot OCR instead of
        // pretending that an entire page was submitted.
        guard let selectionRange else { return nil }
        let utf16Length = text.utf16.count
        let caret = min(max(selectionRange.lowerBound, 0), utf16Length)

        if terminal {
            guard let line = line(containingUTF16Offset: caret, in: text) else { return nil }
            return plausibleSubmission(
                stripTerminalPrompt(from: line),
                limit: limit,
                rejectTerminalStatus: true
            )
        }

        guard isEditableRole(focusedRole) else { return nil }
        if let paragraph = paragraph(containingUTF16Offset: caret, in: text),
           paragraph.utf16.count <= limit,
           paragraph.components(separatedBy: .newlines).count <= 8,
           let submission = plausibleSubmission(paragraph, limit: limit) {
            return submission
        }
        guard let line = line(containingUTF16Offset: caret, in: text) else { return nil }
        return plausibleSubmission(line, limit: limit)
    }

    private static func line(containingUTF16Offset caret: Int, in text: String) -> String? {
        let value = text as NSString
        let length = value.length
        guard length > 0 else { return nil }
        let safeCaret = min(max(caret, 0), length)
        let searchLocation = safeCaret == length ? max(0, length - 1) : safeCaret
        var range = value.lineRange(for: NSRange(location: searchLocation, length: 0))

        // A caret at the beginning of a newly-created blank line does not prove
        // what was submitted. The cached pre-Return snapshot should supply the
        // prior line; otherwise OCR is the safer fallback.
        let candidate = value.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty, safeCaret > 0 {
            let priorScalar = value.substring(with: NSRange(location: safeCaret - 1, length: 1))
            if priorScalar != "\n" && priorScalar != "\r" {
                range = value.lineRange(for: NSRange(location: safeCaret - 1, length: 0))
            }
        }
        let result = value.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func paragraph(containingUTF16Offset caret: Int, in text: String) -> String? {
        let value = text as NSString
        let length = value.length
        guard length > 0 else { return nil }
        let safeCaret = min(max(caret, 0), length)
        guard let separator = try? NSRegularExpression(pattern: "\\n[ \\t]*\\n") else {
            return nil
        }
        let beforeRange = NSRange(location: 0, length: safeCaret)
        let precedingBreak = separator.matches(in: text, range: beforeRange).last?.range
        let start = precedingBreak == nil
            ? 0
            : precedingBreak!.location + precedingBreak!.length
        let afterRange = NSRange(location: safeCaret, length: length - safeCaret)
        let followingBreak = separator.firstMatch(in: text, range: afterRange)?.range
        let end = followingBreak?.location ?? length
        guard end > start else { return nil }
        let result = value.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func stripTerminalPrompt(from value: String) -> String {
        let strippedANSI = value.replacingOccurrences(
            of: "\\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        return strippedANSI.replacingOccurrences(
            of: #"^(?:(?:\[[^\]]+\]|\([^\)]+\))\s*)?(?:[\p{L}\p{N}_.@~/:\\-]+\s+)?[❯›>$%➜»]+\s*"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func plausibleSubmission(
        _ value: String,
        limit: Int,
        rejectTerminalStatus: Bool = false
    ) -> String? {
        let text = value
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2,
              text.utf16.count <= max(limit * 2, limit),
              contentCharacterCount(text) >= 2 else {
            return nil
        }
        if rejectTerminalStatus && looksLikeTerminalStatus(text) { return nil }
        return String(text.prefix(limit))
    }

    private static func looksLikeTerminalStatus(_ value: String) -> Bool {
        let normalized = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return normalized.range(
            of: #"^\d+(?:\.\d+)?\s+(?:tokens?|tok|sol)(?:\s+\S{1,8})?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizedMultiline(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0000}", with: "")
    }

    private static func isEditableRole(_ role: String?) -> Bool {
        guard let role = role?.lowercased() else { return false }
        return isDirectTextInputRole(role)
            || role.contains("textarea")
            || role.contains("webarea")
            || role.contains("document")
    }

    private static func isDirectTextInputRole(_ role: String?) -> Bool {
        guard let role = role?.lowercased() else { return false }
        return role.contains("textfield")
            || role.contains("textarea")
            || role.contains("combobox")
    }

    private static func isTerminalLike(
        applicationName: String?,
        bundleIdentifier: String?
    ) -> Bool {
        let haystack = [applicationName, bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let terms = [
            "terminal", "iterm", "warp", "ghostty", "alacritty", "kitty",
            "wezterm", "hyper", "tabby", "rio", "kimi code", "codex"
        ]
        return terms.contains { haystack.contains($0) }
    }

    private static func contentCharacterCount(_ value: String) -> Int {
        value.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
    }
}
