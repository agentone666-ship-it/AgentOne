import XCTest
@testable import AgentOneCore

final class SubmittedTextReconcilerTests: XCTestCase {
    func testOneLetterChineseIMETailUsesCommittedROIOCR() {
        let result = SubmittedTextReconciler.reconcile(
            draftText: "我给你反馈的问题都做完了？特别是s",
            screenText: """
            我给你反馈的问题都做完了？特别是识别输入框
            我给你反馈的问题都做完了？特别是识别输入框
            """
        )

        XCTAssertEqual(result, "我给你反馈的问题都做完了？特别是识别输入框")
    }

    func testSeparatedEnglishTokenIsNotTreatedAsPinyin() {
        let result = SubmittedTextReconciler.reconcile(
            draftText: "这个接口使用 GPT",
            screenText: "这个接口使用通用模型\nSettings"
        )

        XCTAssertEqual(result, "这个接口使用 GPT")
    }

    func testMixedCaseAttachedEnglishSuffixIsNotTreatedAsPinyin() {
        let result = SubmittedTextReconciler.reconcile(
            draftText: "发布版本vNext",
            screenText: "发布版本五\nSettings"
        )

        XCTAssertEqual(result, "发布版本vNext")
    }

    func testUnrelatedOCRCannotReplaceDraft() {
        let result = SubmittedTextReconciler.reconcile(
            draftText: "我正在写 ADHD 论文",
            screenText: "音乐播放列表\n视频推荐\n设置"
        )

        XCTAssertEqual(result, "我正在写 ADHD 论文")
    }
}
