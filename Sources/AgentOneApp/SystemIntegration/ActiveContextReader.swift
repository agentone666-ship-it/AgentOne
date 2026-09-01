import AppKit
import ApplicationServices
import AgentOneCore
import Foundation

struct ActiveApplicationContext: Sendable {
    let capturedAt: Date
    /// The process that owned the AX snapshot at capture time. Return capture
    /// must keep this PID instead of querying the frontmost application again
    /// from an asynchronous ScreenCaptureKit startup task: a system panel or
    /// AgentOne's own floating UI can become frontmost in that small gap.
    let processIdentifier: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let windowIdentifier: String?
    let url: URL?
    let documentPath: String?
    let visibleText: String?
    let selectedText: String?
    let focusedText: String?
    /// UTF-16 offsets relative to `focusedText`, matching AX/NSString.
    let focusedSelectionRange: Range<Int>?
    let focusedRole: String?
    /// Global Quartz frame of the focused window. Keeping this beside the
    /// focused control lets Return capture reject a stale click in a sidebar
    /// even when Electron exposes no editable AX role for its composer.
    let windowFrame: CGRect?
    let focusedFrame: CGRect?
    /// A small global frame around the AX insertion point/selection. This lets
    /// Return capture reduce large editors and terminal scrollback surfaces to
    /// the paragraph the user was actually submitting.
    let focusedCaretFrame: CGRect?
    let isSecureInput: Bool
}

struct ActiveInteractionTarget: Sendable {
    let role: String?
    let title: String?
    let value: String?
    let url: URL?
    let identifier: String?

    var summary: String? {
        let parts = [
            role.map { $0.replacingOccurrences(of: "AX", with: "") },
            title,
            value,
            url?.absoluteString,
            identifier
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        let unique = parts.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        return String(unique.joined(separator: " · ").prefix(600))
    }
}

/// Reads a bounded snapshot of the currently focused accessibility tree.
///
/// This is intentionally not a recorder and never reads keyboard events as
/// characters. It samples the semantic surface that the foreground app already
/// exposes to macOS Accessibility: page/document title, URL, visible text,
/// selection and the focused editor value. Password fields and their subtrees
/// are skipped before any value attribute is requested.
enum ActiveContextReader {
    enum Scope {
        /// Reads the focused control, its containing window and direct URL
        /// attributes. It deliberately avoids walking the target app's AX tree.
        case focusedElement
        /// Adds bounded browser-tree URL discovery and visible-window text.
        case full
    }

    private static let maximumVisibleCharacters = 12_000
    private static let maximumFocusedCharacters = 6_000
    private static let maximumSelectedCharacters = 3_000
    private static let maximumVisitedElements = 240
    private static let maximumTraversalDepth = 8

    static func read(scope: Scope = .full) -> ActiveApplicationContext? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return read(application: application, scope: scope)
    }

    /// Reads a specific running application. Production callers normally use
    /// `read(scope:)`; the explicit variant is also useful for validating the
    /// exact WeChat/Feishu/Codex process without allowing the test runner or a
    /// macOS system surface to replace the target between activation and AX
    /// sampling.
    static func read(
        application: NSRunningApplication,
        scope: Scope = .full
    ) -> ActiveApplicationContext? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedWindow = elementAttribute(appElement, kAXFocusedWindowAttribute as String)
        let focusedElement = elementAttribute(appElement, kAXFocusedUIElementAttribute as String)

        let windowTitle = normalized(
            stringAttribute(focusedWindow, kAXTitleAttribute as String)
                ?? frontmostWindowTitle(processIdentifier: application.processIdentifier)
        )
        let windowIdentifier = stringAttribute(focusedWindow, "AXIdentifier")

        let focusedRole = stringAttribute(focusedElement, kAXRoleAttribute as String)
        let focusedSubrole = stringAttribute(focusedElement, kAXSubroleAttribute as String)
        let secureInput = isSecure(role: focusedRole, subrole: focusedSubrole)
        let windowFrame = frame(of: focusedWindow)
        let focusedFrame = secureInput ? nil : frame(of: focusedElement)
        let rawFocusedSelectionRange = secureInput ? nil : rangeAttribute(
            focusedElement,
            kAXSelectedTextRangeAttribute as String
        )
        let focusedCaretFrame = secureInput ? nil : caretFrame(
            of: focusedElement,
            selectionRange: rawFocusedSelectionRange
        )

        let selectedText = secureInput ? nil : bounded(
            stringAttribute(focusedElement, kAXSelectedTextAttribute as String),
            limit: maximumSelectedCharacters
        )
        let focusedSnapshot = secureInput ? nil : boundedFocusedSnapshot(
            meaningfulValue(of: focusedElement, role: focusedRole),
            selectionRange: rawFocusedSelectionRange,
            limit: maximumFocusedCharacters
        )
        let focusedText = focusedSnapshot?.text
        let focusedSelectionRange = focusedSnapshot?.selectionRange

        let document = normalized(
            stringAttribute(focusedElement, kAXDocumentAttribute as String)
                ?? stringAttribute(focusedWindow, kAXDocumentAttribute as String)
                ?? stringAttribute(appElement, kAXDocumentAttribute as String)
        )
        let documentURL = document.flatMap(parseURL)
        let url: URL?
        if scope == .full, BrowserContextURLResolver.isBrowser(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        ) {
            let browserSnapshot = browserAccessibilitySnapshot(
                from: focusedWindow ?? appElement,
                focusedElement: focusedElement
            )
            url = BrowserContextURLResolver.resolve(
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.localizedName,
                addressBarCandidates: browserSnapshot.addressBarCandidates,
                fallbackURLs: browserSnapshot.pageURLCandidates + [
                    stringAttribute(focusedElement, kAXURLAttribute as String),
                    stringAttribute(focusedWindow, kAXURLAttribute as String),
                    stringAttribute(appElement, kAXURLAttribute as String),
                    documentURL.flatMap { $0.isFileURL ? nil : $0.absoluteString }
                ]
            )
        } else {
            let rawURL = firstURL(
                in: [
                    urlAttribute(focusedElement, kAXURLAttribute as String),
                    urlAttribute(focusedWindow, kAXURLAttribute as String),
                    urlAttribute(appElement, kAXURLAttribute as String)
                ]
            )
            url = rawURL ?? documentURL.flatMap { $0.isFileURL ? nil : $0 }
        }
        let documentPath: String?
        if let documentURL, documentURL.isFileURL {
            documentPath = documentURL.path
        } else if let document, document.hasPrefix("/") {
            documentPath = document
        } else {
            documentPath = nil
        }

        let visibleText = secureInput || scope == .focusedElement ? nil : focusedWindow.flatMap {
            collectVisibleText(from: $0, excluding: focusedElement)
        }

        return ActiveApplicationContext(
            capturedAt: Date(),
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "Unknown",
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: windowTitle,
            windowIdentifier: windowIdentifier,
            url: url,
            documentPath: documentPath,
            visibleText: visibleText,
            selectedText: selectedText,
            focusedText: focusedText,
            focusedSelectionRange: focusedSelectionRange,
            focusedRole: focusedRole,
            windowFrame: windowFrame,
            focusedFrame: focusedFrame,
            focusedCaretFrame: focusedCaretFrame,
            isSecureInput: secureInput
        )
    }

    /// Resolves the control under a global Quartz mouse position without
    /// assuming that a left click necessarily navigated. The runtime compares
    /// the surrounding Context after the click before adding navigation
    /// semantics.
    static func interactionTarget(at quartzPoint: CGPoint) -> ActiveInteractionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            appElement,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &rawElement
        )
        guard result == .success, let element = rawElement else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute as String)
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        guard !isSecure(role: role, subrole: subrole) else { return nil }
        let title = bounded(
            stringAttribute(element, kAXTitleAttribute as String)
                ?? stringAttribute(element, kAXDescriptionAttribute as String),
            limit: 240
        )
        let value = bounded(meaningfulValue(of: element, role: role), limit: 240)
        let url = urlAttribute(element, kAXURLAttribute as String)
        let identifier = bounded(stringAttribute(element, "AXIdentifier"), limit: 160)
        let target = ActiveInteractionTarget(
            role: role,
            title: title,
            value: value,
            url: url,
            identifier: identifier
        )
        return target.summary == nil ? nil : target
    }

    private static func collectVisibleText(
        from root: AXUIElement,
        excluding focusedElement: AXUIElement?
    ) -> String? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = 0
        var fragments: [String] = []
        var fingerprints: Set<String> = []
        var characterCount = 0

        while index < queue.count,
              visited < maximumVisitedElements,
              characterCount < maximumVisibleCharacters {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let role = stringAttribute(element, kAXRoleAttribute as String)
            let subrole = stringAttribute(element, kAXSubroleAttribute as String)
            if isSecure(role: role, subrole: subrole) { continue }

            if shouldCollectText(for: role), !sameElement(element, focusedElement) {
                let candidates = [
                    stringAttribute(element, kAXTitleAttribute as String),
                    stringAttribute(element, kAXDescriptionAttribute as String),
                    meaningfulValue(of: element, role: role)
                ]
                for candidate in candidates {
                    guard let text = normalized(candidate), text.count >= 2 else { continue }
                    let fingerprint = text.lowercased()
                    guard fingerprints.insert(fingerprint).inserted else { continue }
                    let remaining = maximumVisibleCharacters - characterCount
                    guard remaining > 0 else { break }
                    let clipped = String(text.prefix(remaining))
                    fragments.append(clipped)
                    characterCount += clipped.count + 1
                }
            }

            guard depth < maximumTraversalDepth else { continue }
            queue.append(contentsOf: children(of: element).prefix(80).map { ($0, depth + 1) })
        }

        return bounded(fragments.joined(separator: "\n"), limit: maximumVisibleCharacters)
    }

    private struct BrowserAccessibilitySnapshot {
        var addressBarCandidates: [BrowserAddressBarCandidate]
        var pageURLCandidates: [String?]
    }

    /// The browser toolbar and the web document both live below the focused
    /// window. Address fields are collected separately from AXWebArea URLs so
    /// links inside the page can never outrank the actual address bar.
    private static func browserAccessibilitySnapshot(
        from root: AXUIElement,
        focusedElement: AXUIElement?
    ) -> BrowserAccessibilitySnapshot {
        var queue: [(AXUIElement, Int)] = []
        if let focusedElement { queue.append((focusedElement, 0)) }
        if !sameElement(root, focusedElement) { queue.append((root, 0)) }
        var index = 0
        var visited = 0
        var addressBars: [BrowserAddressBarCandidate] = []
        var pageURLs: [String?] = []

        while index < queue.count, visited < maximumVisitedElements {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let role = stringAttribute(element, kAXRoleAttribute as String)
            let subrole = stringAttribute(element, kAXSubroleAttribute as String)
            guard !isSecure(role: role, subrole: subrole) else { continue }

            if ["AXTextField", "AXComboBox", "AXSearchField"].contains(role ?? "") {
                addressBars.append(BrowserAddressBarCandidate(
                    role: role,
                    title: bounded(stringAttribute(element, kAXTitleAttribute as String), limit: 300),
                    description: bounded(stringAttribute(element, kAXDescriptionAttribute as String), limit: 300),
                    identifier: bounded(stringAttribute(element, "AXIdentifier"), limit: 300),
                    value: bounded(stringAttribute(element, kAXValueAttribute as String), limit: 4_096),
                    url: bounded(stringAttribute(element, kAXURLAttribute as String), limit: 4_096)
                ))
            }

            if role == "AXWebArea" || role == "AXDocument" {
                pageURLs.append(stringAttribute(element, kAXURLAttribute as String))
                pageURLs.append(stringAttribute(element, kAXDocumentAttribute as String))
                // Page descendants contain ordinary links and are not useful
                // for identifying the current top-level page.
                continue
            }

            guard depth < maximumTraversalDepth else { continue }
            queue.append(contentsOf: children(of: element).prefix(80).map { ($0, depth + 1) })
        }

        return BrowserAccessibilitySnapshot(
            addressBarCandidates: addressBars,
            pageURLCandidates: pageURLs
        )
    }

    private static func shouldCollectText(for role: String?) -> Bool {
        guard let role else { return false }
        return [
            "AXStaticText", "AXHeading", "AXTextArea", "AXTextField",
            "AXLink", "AXWebArea", "AXDocument", "AXCell", "AXRow",
            "AXListItem", "AXGroup"
        ].contains(role)
    }

    private static func meaningfulValue(of element: AXUIElement?, role: String?) -> String? {
        guard let element else { return nil }
        guard role != "AXButton", role != "AXCheckBox", role != "AXRadioButton" else { return nil }
        return stringAttribute(element, kAXValueAttribute as String)
    }

    private static func isSecure(role: String?, subrole: String?) -> Bool {
        role == kAXSecureTextFieldSubrole as String
            || subrole == kAXSecureTextFieldSubrole as String
            || role?.localizedCaseInsensitiveContains("secure") == true
            || subrole?.localizedCaseInsensitiveContains("secure") == true
    }

    private static func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement?) -> Bool {
        guard let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func elementAttribute(_ element: AXUIElement?, _ attribute: String) -> AXUIElement? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func frame(of element: AXUIElement?) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute as String),
              let size = sizeAttribute(element, kAXSizeAttribute as String),
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func caretFrame(
        of element: AXUIElement?,
        selectionRange: Range<Int>?
    ) -> CGRect? {
        guard let element, let selectionRange else { return nil }
        let insertion = selectionRange.upperBound
        var candidateRanges = [CFRange(location: insertion, length: 0)]
        if insertion > 0 {
            candidateRanges.append(CFRange(location: insertion - 1, length: 1))
        }
        if selectionRange.lowerBound < selectionRange.upperBound {
            candidateRanges.append(
                CFRange(
                    location: selectionRange.lowerBound,
                    length: selectionRange.upperBound - selectionRange.lowerBound
                )
            )
        }

        for range in candidateRanges {
            guard var bounds = boundsForRange(of: element, range: range),
                  bounds.height > 1 else {
                continue
            }
            if bounds.width < 2 {
                bounds.origin.x -= 1
                bounds.size.width = 2
            }
            return bounds
        }
        return nil
    }

    private static func boundsForRange(of element: AXUIElement, range: CFRange) -> CGRect? {
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var rawValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &bounds) else { return nil }
        return bounds
    }

    private static func pointAttribute(_ element: AXUIElement?, _ attribute: String) -> CGPoint? {
        guard let value = axValueAttribute(element, attribute),
              AXValueGetType(value) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement?, _ attribute: String) -> CGSize? {
        guard let value = axValueAttribute(element, attribute),
              AXValueGetType(value) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func rangeAttribute(_ element: AXUIElement?, _ attribute: String) -> Range<Int>? {
        guard let value = axValueAttribute(element, attribute),
              AXValueGetType(value) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return range.location..<(range.location + range.length)
    }

    private static func axValueAttribute(_ element: AXUIElement?, _ attribute: String) -> AXValue? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func stringAttribute(_ element: AXUIElement?, _ attribute: String) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func urlAttribute(_ element: AXUIElement?, _ attribute: String) -> URL? {
        guard let raw = stringAttribute(element, attribute) else { return nil }
        return parseURL(raw)
    }

    private static func parseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.contains("."), !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        return nil
    }

    private static func firstURL(in values: [URL?]) -> URL? {
        values.compactMap { $0 }.first
    }

    private static func frontmostWindowTitle(processIdentifier: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return windows.first { window in
            (window[kCGWindowOwnerPID as String] as? Int32) == processIdentifier
                && (window[kCGWindowLayer as String] as? Int ?? 1) == 0
        }?[kCGWindowName as String] as? String
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let normalized = normalized(value) else { return nil }
        return String(normalized.prefix(limit))
    }

    private struct FocusedTextSnapshot {
        var text: String
        var selectionRange: Range<Int>?
    }

    /// Keep a window around the AX caret instead of always taking the first
    /// 6,000 characters. Terminal-style AXTextAreas often contain the entire
    /// scrollback buffer and the active prompt is at the end.
    private static func boundedFocusedSnapshot(
        _ value: String?,
        selectionRange: Range<Int>?,
        limit: Int
    ) -> FocusedTextSnapshot? {
        guard let value, limit > 0,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let string = value as NSString
        let length = string.length
        let clampedSelection = selectionRange.map { range in
            let lower = min(max(range.lowerBound, 0), length)
            let upper = min(max(range.upperBound, lower), length)
            return lower..<upper
        }
        guard length > limit else {
            return FocusedTextSnapshot(text: value, selectionRange: clampedSelection)
        }

        let anchor = clampedSelection?.lowerBound ?? 0
        var start = max(0, anchor - limit / 2)
        var end = min(length, start + limit)
        if let clampedSelection, clampedSelection.upperBound > end {
            end = min(length, clampedSelection.upperBound)
            start = max(0, end - limit)
        }
        if end - start > limit {
            end = start + limit
        }
        let clipped = string.substring(with: NSRange(location: start, length: end - start))
        let adjusted = clampedSelection.map { range in
            max(0, range.lowerBound - start)..<max(0, min(end, range.upperBound) - start)
        }
        return FocusedTextSnapshot(text: clipped, selectionRange: adjusted)
    }
}
