import Foundation

public enum SimulatedActivityFactory {
    /// A deterministic research-writing flow: read, express a thought, drift into
    /// entertainment, receive a reminder, and return to the paper.
    public static func researchWritingDay(start: Date = Date()) -> [ActivityEvent] {
        let paper = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Attention restoration and cognitive control — Paper",
            url: URL(string: "https://example.org/paper/attention-restoration"),
            contentSummary: "Research paper about attention restoration and cognitive control",
            semanticTags: ["attention", "research", "paper"]
        )
        let editor = ActivityContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Literature review draft",
            contentSummary: "Drafting a literature review about attention restoration",
            selectedText: "Attention recovery depends on reducing context-switching costs.",
            semanticTags: ["attention", "research", "writing"]
        )
        let entertainment = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Funny short videos",
            url: URL(string: "https://video.example/recommendations"),
            contentSummary: "Unrelated entertainment recommendations",
            semanticTags: ["video", "entertainment"]
        )

        return [
            ActivityEvent(timestamp: start, signal: .scrolled(axis: .vertical, delta: 420, phase: .changed), context: paper),
            ActivityEvent(timestamp: start.addingTimeInterval(45), signal: .keyboard(.typingBurst(estimatedCharacterCount: 72)), context: editor),
            ActivityEvent(timestamp: start.addingTimeInterval(75), signal: .keyboard(.returnPressed), context: editor),
            ActivityEvent(timestamp: start.addingTimeInterval(120), signal: .windowFocused(windowIdentifier: "video-window"), context: entertainment),
            ActivityEvent(timestamp: start.addingTimeInterval(310), signal: .scrolled(axis: .vertical, delta: 800, phase: .momentum), context: entertainment),
            ActivityEvent(timestamp: start.addingTimeInterval(440), signal: .windowFocused(windowIdentifier: "editor-window"), context: editor)
        ]
    }
}
