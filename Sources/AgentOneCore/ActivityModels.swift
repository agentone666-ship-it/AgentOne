import Foundation

public struct ScreenPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum MouseButton: String, Codable, Hashable, Sendable {
    case left
    case right
    case middle
    case other
}

public enum ScrollAxis: String, Codable, Hashable, Sendable {
    case vertical
    case horizontal
}

public enum ScrollPhase: String, Codable, Hashable, Sendable {
    case began
    case changed
    case ended
    case momentum
}

/// Keyboard input is intentionally represented as behavior rather than captured text.
/// AgentOne can understand that the user composed, corrected, navigated, or submitted
/// something without becoming a global keylogger.
public enum KeyboardBehavior: Codable, Hashable, Sendable {
    case typingStarted
    case typingBurst(estimatedCharacterCount: Int)
    case typingPaused(milliseconds: Int)
    case returnPressed
    case deletePressed(repeatCount: Int)
    case navigation(key: String)
    case shortcut(name: String)
    case escapePressed
}

public enum ActivitySignal: Codable, Hashable, Sendable {
    case mouseMoved(location: ScreenPoint?)
    case mouseClicked(button: MouseButton, count: Int, location: ScreenPoint?)
    case scrolled(axis: ScrollAxis, delta: Double, phase: ScrollPhase)
    case keyboard(KeyboardBehavior)
    case applicationActivated(bundleIdentifier: String?)
    case windowFocused(windowIdentifier: String?)
    case contentChanged
    case clipboardUsed
    case idleStarted
    case idleEnded
    case voiceConversationStarted
    case voiceConversationEnded
}

public enum HookSemantic: String, Codable, Hashable, Sendable {
    case readingProgress
    case navigation
    case selectionOrActivation
    case compositionStarted
    case compositionContinued
    case reflectionPause
    case revision
    case opinionOutput
    case taskSubmission
    case contextSwitch
    case resumedActivity
    case possibleBreak
    case conversationalPresence
}

public struct ActivityContext: Codable, Hashable, Sendable {
    /// Internal provenance tag for a summary produced by the semantic model.
    /// It is persisted with the context so later raw Accessibility samples do
    /// not replace the human-readable summary with another page-text dump.
    public static let modelEnrichedSummaryTag = "agentone:model-enriched-summary"

    public var applicationName: String?
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var windowIdentifier: String?
    public var url: URL?
    public var documentPath: String?
    public var contentSummary: String?
    public var selectedText: String?
    /// Text that was present in the focused editor immediately before a
    /// submit-like Return. This comes from Accessibility, never from a global
    /// character logger.
    public var submittedText: String?
    /// Bounded OCR from a user-authorized key screenshot. It is a fallback for
    /// apps whose editors do not expose their value through Accessibility.
    public var screenText: String?
    /// Human-readable Accessibility description of the control underneath a
    /// primary click.
    public var interactionTarget: String?
    /// A compact before/after description produced after a click settles.
    public var contextTransition: String?
    /// Local-only path to the key screenshot. Model serializers deliberately
    /// omit this path and send only the sanitized textual context.
    public var screenshotResourcePath: String?
    public var semanticTags: Set<String>
    public var isSensitive: Bool

    public init(
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        url: URL? = nil,
        documentPath: String? = nil,
        contentSummary: String? = nil,
        selectedText: String? = nil,
        submittedText: String? = nil,
        screenText: String? = nil,
        interactionTarget: String? = nil,
        contextTransition: String? = nil,
        screenshotResourcePath: String? = nil,
        semanticTags: Set<String> = [],
        isSensitive: Bool = false
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
        self.url = url
        self.documentPath = documentPath
        self.contentSummary = contentSummary
        self.selectedText = selectedText
        self.submittedText = submittedText
        self.screenText = screenText
        self.interactionTarget = interactionTarget
        self.contextTransition = contextTransition
        self.screenshotResourcePath = screenshotResourcePath
        self.semanticTags = semanticTags
        self.isSensitive = isSensitive
    }

    public var searchableText: String {
        [
            applicationName,
            windowTitle,
            url?.absoluteString,
            documentPath,
            contentSummary,
            selectedText,
            submittedText,
            screenText,
            interactionTarget,
            contextTransition
        ]
            .compactMap { $0 }
            .joined(separator: " ") + " " + semanticTags.joined(separator: " ")
    }

    public var hasModelEnrichedSummary: Bool {
        semanticTags.contains(Self.modelEnrichedSummaryTag)
    }
}

public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var signal: ActivitySignal
    public var context: ActivityContext
    public var semantics: Set<HookSemantic>

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        signal: ActivitySignal,
        context: ActivityContext = ActivityContext(),
        semantics: Set<HookSemantic>? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.signal = signal
        self.context = context
        self.semantics = semantics ?? Self.inferSemantics(for: signal)
    }

    public static func inferSemantics(for signal: ActivitySignal) -> Set<HookSemantic> {
        switch signal {
        case .mouseMoved:
            return []
        case .mouseClicked:
            // A left click is only a candidate intention. Navigation is added
            // after the foreground Context actually changes.
            return [.selectionOrActivation]
        case .scrolled:
            return [.readingProgress, .navigation]
        case .keyboard(let behavior):
            switch behavior {
            case .typingStarted:
                return [.compositionStarted]
            case .typingBurst:
                return [.compositionContinued]
            case .typingPaused:
                return [.reflectionPause]
            case .returnPressed:
                return [.opinionOutput, .taskSubmission]
            case .deletePressed:
                return [.revision]
            case .navigation:
                return [.navigation]
            case .shortcut(let name):
                let normalized = name.lowercased()
                if normalized.contains("save") || normalized == "⌘s" {
                    return [.taskSubmission]
                }
                return [.navigation]
            case .escapePressed:
                return [.navigation]
            }
        case .applicationActivated, .windowFocused:
            return [.contextSwitch]
        case .contentChanged:
            return [.compositionContinued]
        case .clipboardUsed:
            return [.selectionOrActivation]
        case .idleStarted:
            return [.possibleBreak]
        case .idleEnded:
            return [.resumedActivity]
        case .voiceConversationStarted, .voiceConversationEnded:
            return [.conversationalPresence]
        }
    }
}
