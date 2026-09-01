import Foundation
import Testing
@testable import AgentOneCore

@Suite
struct FocusedTextSubmissionExtractorTests {
    @Test
    func shortWebAreaWithoutCaretNeverBecomesSubmittedText() {
        let extracted = FocusedTextSubmissionExtractor.extract(
            focusedText: "aidc 板块",
            selectionRange: nil,
            applicationName: "微信",
            bundleIdentifier: "com.tencent.xinWeChat",
            focusedRole: "AXWebArea"
        )

        #expect(extracted == nil)
    }

    @Test
    func shortDocumentWithoutCaretNeverBecomesSubmittedText() {
        let extracted = FocusedTextSubmissionExtractor.extract(
            focusedText: "飞书会话列表",
            selectionRange: nil,
            applicationName: "飞书",
            bundleIdentifier: "com.bytedance.macos.feishu",
            focusedRole: "AXDocument"
        )

        #expect(extracted == nil)
    }

    @Test
    func largeWebAreaWithCaretExtractsOnlyCurrentParagraph() {
        let paragraph = "第一行是上下文。\n第二行是用户准备发送的结论。"
        let text = (0..<28)
            .map { "历史页面段落 \($0)" }
            .joined(separator: "\n\n")
            + "\n\n\(paragraph)\n\n后续页面内容"
        let value = text as NSString
        let range = value.range(of: paragraph)
        let caret = NSMaxRange(range)

        let extracted = FocusedTextSubmissionExtractor.extract(
            focusedText: text,
            selectionRange: caret..<caret,
            applicationName: "飞书",
            bundleIdentifier: "com.bytedance.macos.feishu",
            focusedRole: "AXWebArea"
        )

        #expect(extracted == paragraph)
    }
}
