import CoreGraphics
import Foundation
import Testing
@testable import AgentOneCore

@Suite
struct ReturnInputSessionAnchorTests {
    private let window = CGRect(x: 100, y: 50, width: 1_000, height: 800)

    @Test
    func validatedChatAnchorSurvivesConsecutiveReturnsWithoutAnotherClick() throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let anchor = try #require(ReturnInputSessionAnchor(
            point: CGPoint(x: 720, y: 720),
            bundleIdentifier: "com.openai.codex",
            windowIdentifier: "main",
            windowFrame: window,
            capturedAt: timestamp
        ))

        let restored = anchor.resolvedPoint(
            bundleIdentifier: "com.openai.codex",
            windowIdentifier: "main",
            windowFrame: window,
            focusedFrame: nil,
            caretFrame: nil,
            profile: .codex,
            at: timestamp.addingTimeInterval(60)
        )

        #expect(restored == CGPoint(x: 720, y: 720))
    }

    @Test
    func anchorRebasesWhenWindowMovesAndResizes() throws {
        let timestamp = Date(timeIntervalSince1970: 11_000)
        let anchor = try #require(ReturnInputSessionAnchor(
            point: CGPoint(x: 720, y: 720),
            bundleIdentifier: "com.tencent.xinWeChat",
            windowIdentifier: "chat",
            windowFrame: window,
            capturedAt: timestamp
        ))
        let moved = CGRect(x: 300, y: 100, width: 1_200, height: 900)

        let restored = try #require(anchor.resolvedPoint(
            bundleIdentifier: "com.tencent.xinWeChat",
            windowIdentifier: "chat",
            windowFrame: moved,
            focusedFrame: nil,
            caretFrame: nil,
            profile: .weChat,
            at: timestamp.addingTimeInterval(120)
        ))

        #expect(abs(restored.x - 1_044) < 0.01)
        #expect(abs(restored.y - 853.75) < 0.01)
    }

    @Test
    func differentApplicationOrWindowRejectsRetainedAnchor() throws {
        let timestamp = Date(timeIntervalSince1970: 12_000)
        let anchor = try #require(ReturnInputSessionAnchor(
            point: CGPoint(x: 720, y: 720),
            bundleIdentifier: "com.bytedance.macos.feishu",
            windowIdentifier: "chat-a",
            windowFrame: window,
            capturedAt: timestamp
        ))

        #expect(anchor.resolvedPoint(
            bundleIdentifier: "com.openai.codex",
            windowIdentifier: "chat-a",
            windowFrame: window,
            focusedFrame: nil,
            caretFrame: nil,
            profile: .codex,
            at: timestamp.addingTimeInterval(1)
        ) == nil)
        #expect(anchor.resolvedPoint(
            bundleIdentifier: "com.bytedance.macos.feishu",
            windowIdentifier: "chat-b",
            windowFrame: window,
            focusedFrame: nil,
            caretFrame: nil,
            profile: .feishu,
            at: timestamp.addingTimeInterval(1)
        ) == nil)
    }

    @Test
    func concreteMiddleEditorRejectsOldBottomChatAnchor() throws {
        let timestamp = Date(timeIntervalSince1970: 13_000)
        let anchor = try #require(ReturnInputSessionAnchor(
            point: CGPoint(x: 720, y: 720),
            bundleIdentifier: "com.bytedance.macos.feishu",
            windowIdentifier: "main",
            windowFrame: window,
            capturedAt: timestamp
        ))

        #expect(anchor.resolvedPoint(
            bundleIdentifier: "com.bytedance.macos.feishu",
            windowIdentifier: "main",
            windowFrame: window,
            focusedFrame: CGRect(x: 300, y: 250, width: 600, height: 90),
            caretFrame: nil,
            profile: .feishu,
            at: timestamp.addingTimeInterval(1)
        ) == nil)
    }
}
