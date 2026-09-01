import CoreGraphics
import Testing
@testable import AgentOneCore

@Suite
struct ReturnInputCaptureContractTests {
    private let window = CGRect(x: 0, y: 0, width: 1_200, height: 800)

    @Test
    func knownApplicationProfilesResolveFromBundleAndName() {
        #expect(ReturnInputComposerProfile.resolve(
            bundleIdentifier: "com.tencent.xinWeChat",
            applicationName: nil
        ) == .weChat)
        #expect(ReturnInputComposerProfile.resolve(
            bundleIdentifier: "com.openai.codex",
            applicationName: nil
        ) == .codex)
        #expect(ReturnInputComposerProfile.resolve(
            bundleIdentifier: "com.bytedance.macos.feishu",
            applicationName: nil
        ) == .feishu)
        #expect(ReturnInputComposerProfile.resolve(
            bundleIdentifier: "com.bytedance.ee.larkmac",
            applicationName: nil
        ) == .feishu)
        #expect(ReturnInputComposerProfile.resolve(
            bundleIdentifier: nil,
            applicationName: "微信"
        ) == .weChat)
    }

    @Test
    func weChatSidebarFocusCannotBecomeTrustedInputOrTypingAnchorBlocker() {
        let sidebarSearch = CGRect(x: 22, y: 44, width: 214, height: 36)
        let composerClick = CGPoint(x: 780, y: 724)

        #expect(!ReturnInputComposerProfile.weChat.acceptsTrustedInputGeometry(
            sidebarSearch,
            in: window
        ))
        #expect(ReturnInputComposerProfile.weChat.validatesTypingAnchor(
            composerClick,
            focusedFrame: sidebarSearch,
            caretFrame: nil,
            in: window
        ))
        #expect(!ReturnInputComposerProfile.weChat.validatesTypingAnchor(
            CGPoint(x: 120, y: 724),
            focusedFrame: sidebarSearch,
            caretFrame: nil,
            in: window
        ))
    }

    @Test
    func feishuSidebarIsRejectedWhileComposerAndMiddleCommentStayTrusted() {
        let sidebarRow = CGRect(x: 18, y: 620, width: 246, height: 68)
        let bottomComposer = CGRect(x: 330, y: 654, width: 760, height: 108)
        let middleComment = CGRect(x: 340, y: 320, width: 650, height: 92)

        #expect(!ReturnInputComposerProfile.feishu.acceptsTrustedInputGeometry(
            sidebarRow,
            in: window
        ))
        #expect(ReturnInputComposerProfile.feishu.acceptsTrustedInputGeometry(
            bottomComposer,
            in: window
        ))
        #expect(ReturnInputComposerProfile.feishu.acceptsTrustedInputGeometry(
            middleComment,
            in: window
        ))
        #expect(ReturnInputComposerProfile.feishu.validatesTypingAnchor(
            CGPoint(x: 760, y: 710),
            focusedFrame: bottomComposer,
            caretFrame: nil,
            in: window
        ))
        #expect(!ReturnInputComposerProfile.feishu.validatesTypingAnchor(
            CGPoint(x: 760, y: 710),
            focusedFrame: middleComment,
            caretFrame: nil,
            in: window
        ))
    }

    @Test
    func codexComposerCropExcludesFooterStatusStrip() {
        let regions = ReturnInputCaptureContract.regions(
            focusedFrame: CGRect(x: 210, y: 630, width: 940, height: 150),
            caretFrame: nil,
            windowFrame: window,
            profile: .codex
        )

        #expect(regions.count == 1)
        let region = regions[0]
        #expect(region.source == .focusedInput)
        #expect(region.y > 0.74)
        #expect(region.y + region.height < 0.96)
    }

    @Test
    func frozenRegionsStayInsideKnownApplicationComposerBounds() {
        let oversized = ReturnInputCaptureRegion(
            x: 0.08,
            y: 0.48,
            width: 0.90,
            height: 0.50,
            source: .caretNeighborhood
        )

        let weChat = ReturnInputCaptureContract.constrainedPreSubmissionRegion(
            oversized,
            profile: .weChat
        )
        let feishu = ReturnInputCaptureContract.constrainedPreSubmissionRegion(
            oversized,
            profile: .feishu
        )
        #expect((weChat?.x ?? 0) >= 0.28)
        #expect((weChat?.y ?? 0) >= 0.67)
        #expect((weChat?.maxX ?? 1) <= 0.995)
        #expect((feishu?.x ?? 0) >= 0.24)
        #expect((feishu?.y ?? 0) >= 0.61)
        #expect((feishu?.maxX ?? 1) <= 0.995)

        let codex = ReturnInputCaptureContract.constrainedPreSubmissionRegion(
            ReturnInputCaptureRegion(
                x: 0.20,
                y: 0.74,
                width: 0.72,
                height: 0.24,
                source: .focusedInput
            ),
            profile: .codex
        )
        #expect(codex != nil)
        #expect((codex?.maxY ?? 1) <= 0.955)
    }

    @Test
    func codexSharingStripIsRejectedAsInterfaceChrome() {
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("你正在共享屏幕"))
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("正在共享屏幕"))
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("You are sharing your screen"))
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("Screen Sharing"))
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("停止共享"))
    }

    @Test
    func codexBottomStatusBaselineRejectsEvenGarbledOCR() {
        let frozen = ReturnInputCaptureRegion(
            x: 0.20,
            y: 0.70,
            width: 0.72,
            height: 0.245,
            source: .focusedInput
        )
        let lines = ReturnInputCaptureContract.spatiallyValidPreSubmissionLines(
            [
                NormalizedOCRLine(
                    text: "Codex current message",
                    x: 0.18,
                    y: 0.48,
                    width: 0.46,
                    height: 0.10
                ),
                NormalizedOCRLine(
                    text: "PDTF Aa",
                    x: 0.74,
                    y: 0.01,
                    width: 0.18,
                    height: 0.08
                )
            ],
            within: frozen,
            profile: .codex
        )

        #expect(lines.map(\.text) == ["Codex current message"])
    }

    @Test
    func frozenComposerOCRSelectsCurrentTextInsteadOfOlderBubbleOrFooter() {
        let current = "AGENTONE_CODEX_RETURN_20260812_02"
        let lines = ReturnInputCaptureContract.preSubmissionEvidenceLines(
            [
                NormalizedOCRLine(
                    text: "AGENTONE_CODEX_RETURN_20260812_01",
                    x: 0.18,
                    y: 0.68,
                    width: 0.52,
                    height: 0.07
                ),
                NormalizedOCRLine(
                    text: current,
                    x: 0.18,
                    y: 0.26,
                    width: 0.52,
                    height: 0.07
                ),
                NormalizedOCRLine(
                    text: "你正在共享屏幕",
                    x: 0.18,
                    y: 0.02,
                    width: 0.28,
                    height: 0.06
                )
            ],
            referenceText: current
        )

        #expect(lines.map(\.text) == [current])
    }

    @Test
    func noDraftUsesLowestMeaningfulBlockInsideFrozenComposer() {
        let lines = ReturnInputCaptureContract.preSubmissionEvidenceLines(
            [
                NormalizedOCRLine(
                    text: "飞书上方已发送的气泡",
                    x: 0.16,
                    y: 0.70,
                    width: 0.44,
                    height: 0.07
                ),
                NormalizedOCRLine(
                    text: "连续第三条消息",
                    x: 0.16,
                    y: 0.25,
                    width: 0.36,
                    height: 0.07
                ),
                NormalizedOCRLine(
                    text: "发送",
                    x: 0.82,
                    y: 0.02,
                    width: 0.10,
                    height: 0.05
                )
            ],
            referenceText: nil
        )

        #expect(lines.map(\.text) == ["连续第三条消息"])
    }

    @Test
    func tightCropCannotEscapeTheFrozenInputRegion() {
        let frozen = ReturnInputCaptureRegion(
            x: 0.28,
            y: 0.70,
            width: 0.66,
            height: 0.20,
            source: .caretNeighborhood
        )
        let tightened = ReturnInputCaptureContract.tightenedPreSubmissionRegion(
            within: frozen,
            meaningfulLines: [
                NormalizedOCRLine(
                    text: "微信连续第二条",
                    x: 0.20,
                    y: 0.28,
                    width: 0.42,
                    height: 0.12
                )
            ]
        )

        #expect(tightened != nil)
        #expect((tightened?.x ?? 0) >= frozen.x)
        #expect((tightened?.y ?? 0) >= frozen.y)
        #expect((tightened?.maxX ?? 1) <= frozen.maxX)
        #expect((tightened?.maxY ?? 1) <= frozen.maxY)
    }

    @Test
    func weChatExactReferenceInSidebarCannotEscapeComposerEnvelope() {
        let submitted = "AGENTONE_WECHAT_RETURN_20260812_01"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.03,
                    y: 0.16,
                    width: 0.18,
                    height: 0.035,
                    confidence: 1
                ),
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.40,
                    y: 0.08,
                    width: 0.38,
                    height: 0.035,
                    confidence: 0.92
                )
            ],
            focusedFrame: CGRect(x: 20, y: 44, width: 214, height: 36),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted,
            interactionPoint: CGPoint(x: 760, y: 724),
            profile: .weChat
        )

        #expect(regions.count == 1)
        #expect((regions.first?.x ?? 0) > 0.30)
        #expect((regions.first?.y ?? 0) > 0.80)
    }

    @Test
    func smallWindowKnownProfileUsesRelativeComposerBounds() {
        let smallWindow = CGRect(x: -620, y: 80, width: 520, height: 420)
        let composerPoint = CGPoint(x: -300, y: 450)
        let sidebarPoint = CGPoint(x: -560, y: 450)

        #expect(ReturnInputComposerProfile.weChat.acceptsInputAnchor(
            composerPoint,
            in: smallWindow
        ))
        #expect(!ReturnInputComposerProfile.weChat.acceptsInputAnchor(
            sidebarPoint,
            in: smallWindow
        ))
    }

    @Test
    func compactFocusedInputProducesOnlyTheRealTopLeftCrop() {
        let regions = ReturnInputCaptureContract.regions(
            focusedFrame: CGRect(x: 240, y: 680, width: 720, height: 72),
            caretFrame: nil,
            windowFrame: window
        )

        #expect(regions.count == 1)
        #expect(regions.first?.source == .focusedInput)
        #expect((regions.first?.y ?? 0) > 0.78)
        #expect(!regions.contains(where: { $0.y < 0.25 }))
    }

    @Test
    func identicalHistoryTextCannotBeatFocusedComposer() {
        let submitted = "这是用户刚刚在输入框里写下的观点，需要被准确捕获"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                // Vision uses lower-left coordinates. This identical history
                // bubble is near the top after conversion to screen space.
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.38,
                    y: 0.64,
                    width: 0.44,
                    height: 0.035,
                    confidence: 0.99
                ),
                // The same text is still visible in the bottom composer on the
                // immutable screenshot captured for the Return event.
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.38,
                    y: 0.10,
                    width: 0.44,
                    height: 0.035,
                    confidence: 0.94
                )
            ],
            focusedFrame: CGRect(x: 240, y: 680, width: 720, height: 72),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted
        )

        #expect(regions.count == 1)
        #expect((regions.first?.y ?? 0) > 0.78)
        #expect(!regions.contains(where: { $0.y < 0.35 }))
    }

    @Test
    func sentBubbleOutsideClearedComposerIsRejected() {
        let submitted = "我不行了"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.38,
                    y: 0.34,
                    width: 0.16,
                    height: 0.04,
                    confidence: 0.99
                )
            ],
            focusedFrame: CGRect(x: 240, y: 680, width: 720, height: 72),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted
        )

        #expect(regions.isEmpty)

        let accessibilityFallback = ReturnInputCaptureContract.regions(
            focusedFrame: CGRect(x: 240, y: 680, width: 720, height: 72),
            caretFrame: nil,
            windowFrame: window
        )
        #expect(accessibilityFallback.count == 1)
        #expect((accessibilityFallback.first?.y ?? 0) > 0.78)
    }

    @Test
    func weChatImmediatelySentBubbleCanRecoverClearedComposerWithoutSidebar() {
        let submitted = "AGENTONE_WECHAT_RETURN_20260812_02"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.03,
                    y: 0.18,
                    width: 0.18,
                    height: 0.035,
                    confidence: 0.99
                ),
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.63,
                    y: 0.24,
                    width: 0.28,
                    height: 0.035,
                    confidence: 0.94
                )
            ],
            focusedFrame: CGRect(x: 330, y: 680, width: 820, height: 92),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted,
            interactionPoint: CGPoint(x: 760, y: 720),
            profile: .weChat
        )

        #expect(regions.count == 1)
        #expect(regions.first?.source == .inferredComposerRegion)
        #expect((regions.first?.x ?? 0) > 0.55)
        #expect((regions.first?.width ?? 1) < 0.40)
        #expect((regions.first?.y ?? 0) > 0.65)
    }

    @Test
    func oldMatchingHistoryAboveRecoveryBandCannotReplaceClearedComposer() {
        let submitted = "AGENTONE_WECHAT_RETURN_20260812_03"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.56,
                    y: 0.66,
                    width: 0.32,
                    height: 0.035,
                    confidence: 0.99
                )
            ],
            focusedFrame: CGRect(x: 330, y: 680, width: 820, height: 92),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted,
            interactionPoint: CGPoint(x: 760, y: 720),
            profile: .weChat
        )

        #expect(regions.isEmpty)
    }

    @Test
    func codexSentTextRecoveryDoesNotIncludeFooterOrStatus() {
        let submitted = "AGENTONE_CODEX_RETURN_20260812_01"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.46,
                    y: 0.23,
                    width: 0.34,
                    height: 0.035,
                    confidence: 0.95
                ),
                NormalizedOCRLine(
                    text: "model: gpt-5 tokens: 188K",
                    x: 0.35,
                    y: 0.02,
                    width: 0.30,
                    height: 0.025,
                    confidence: 0.99
                )
            ],
            focusedFrame: CGRect(x: 210, y: 630, width: 940, height: 150),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted,
            interactionPoint: CGPoint(x: 720, y: 700),
            profile: .codex
        )

        #expect(regions.count == 1)
        #expect((regions.first?.y ?? 0) > 0.65)
        #expect((regions.first?.y ?? 0) + (regions.first?.height ?? 1) < 0.86)
    }

    @Test
    func codexElapsedTimeCannotBecomeTheLocatedSubmission() {
        let submitted = "019ff4fb-7013-7c52-8910-d64ca3d4f558，这两个会话id"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.18,
                    y: 0.105,
                    width: 0.46,
                    height: 0.032,
                    confidence: 0.96
                ),
                NormalizedOCRLine(
                    text: "完全访问",
                    x: 0.19,
                    y: 0.03,
                    width: 0.08,
                    height: 0.025,
                    confidence: 0.98
                ),
                NormalizedOCRLine(
                    text: "5.6 S",
                    x: 0.91,
                    y: 0.025,
                    width: 0.06,
                    height: 0.025,
                    confidence: 0.99
                )
            ],
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: nil,
            interactionPoint: CGPoint(x: 667, y: 702),
            profile: .codex
        )

        #expect(regions.count == 1)
        #expect((regions.first?.height ?? 1) < 0.08)
        #expect((regions.first?.y ?? 0) > 0.82)
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("5.6S"))
        #expect(ReturnInputCaptureContract.isLikelyInterfaceChrome("5.6 S"))
    }

    @Test
    func unrelatedStatusCandidateCannotBeatReferenceDraft() {
        let draft = "请把输入框聚焦修准确"
        let selected = ReturnInputCaptureContract.selectOCRCandidate(
            [
                ReturnInputOCRCandidate(
                    id: 1,
                    source: .caretNeighborhood,
                    recognizedText: "5.6 S",
                    submittedText: "5.6 S",
                    recognizedLineCount: 1,
                    averageConfidence: 0.99
                ),
                ReturnInputOCRCandidate(
                    id: 2,
                    source: .inferredComposerRegion,
                    recognizedText: draft,
                    submittedText: draft,
                    recognizedLineCount: 1,
                    averageConfidence: 0.92
                )
            ],
            referenceText: draft
        )

        #expect(selected?.id == 2)
        #expect(ReturnInputCaptureContract.modelScreenText(
            from: "\(draft)\n完全访问\n5.6 S"
        ) == "回车输入区域 OCR：\n\(draft)")
    }

    @Test
    func feishuBottomChatRecoveryDoesNotStealMiddleEditorReturn() {
        let submitted = "AGENTONE_FEISHU_RETURN_20260812_01"
        let middleEditorRegions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.46,
                    y: 0.24,
                    width: 0.34,
                    height: 0.035,
                    confidence: 0.99
                )
            ],
            focusedFrame: CGRect(x: 340, y: 320, width: 650, height: 92),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted,
            profile: .feishu
        )

        #expect(middleEditorRegions.isEmpty)
    }

    @Test
    func quartzClickAnchorsBottomComposerWithoutMirroringToTop() {
        let submitted = "点击后输入的内容"
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.34,
                    y: 0.62,
                    width: 0.30,
                    height: 0.035,
                    confidence: 0.99
                ),
                NormalizedOCRLine(
                    text: submitted,
                    x: 0.34,
                    y: 0.075,
                    width: 0.30,
                    height: 0.035,
                    confidence: 0.93
                )
            ],
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: submitted,
            interactionPoint: CGPoint(x: 720, y: 720)
        )

        #expect(regions.count == 1)
        #expect((regions.first?.y ?? 0) > 0.80)
        #expect(!regions.contains(where: { $0.y < 0.30 }))
    }

    @Test
    func focusedCommentFieldInMiddleOfPageDoesNotAssumeBottomComposer() {
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: "这是页面中部评论框里的观点",
                    x: 0.26,
                    y: 0.55,
                    width: 0.38,
                    height: 0.04,
                    confidence: 0.96
                ),
                NormalizedOCRLine(
                    text: "页面底部无关推荐",
                    x: 0.26,
                    y: 0.08,
                    width: 0.30,
                    height: 0.04,
                    confidence: 0.99
                )
            ],
            focusedFrame: CGRect(x: 250, y: 310, width: 700, height: 90),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: "这是页面中部评论框里的观点"
        )

        #expect(regions.count == 1)
        #expect((regions.first?.y ?? 0) > 0.35)
        #expect((regions.first?.y ?? 1) < 0.45)
    }

    @Test
    func multilineComposerIsGroupedButMessageAboveItIsExcluded() {
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(text: "上方刚发送的消息不能进来", x: 0.36, y: 0.28, width: 0.36, height: 0.03),
                NormalizedOCRLine(text: "第一行：先定位输入框", x: 0.36, y: 0.145, width: 0.34, height: 0.03),
                NormalizedOCRLine(text: "第二行：再做局部 OCR", x: 0.36, y: 0.105, width: 0.36, height: 0.03),
                NormalizedOCRLine(text: "第三行：交给 Agent 分析", x: 0.36, y: 0.065, width: 0.38, height: 0.03)
            ],
            focusedFrame: CGRect(x: 240, y: 620, width: 720, height: 140),
            caretFrame: CGRect(x: 700, y: 730, width: 2, height: 22),
            windowFrame: window,
            displayFrame: window,
            referenceText: "第一行：先定位输入框\n第二行：再做局部 OCR\n第三行：交给 Agent 分析"
        )

        #expect(regions.count == 1)
        #expect((regions.first?.y ?? 0) > 0.74)
        #expect((regions.first?.height ?? 0) >= 0.17)
        #expect((regions.first?.height ?? 1) < 0.23)
    }

    @Test
    func negativeDisplayOriginRetainsTopLeftWindowCoordinates() {
        let display = CGRect(x: -1_440, y: -200, width: 1_440, height: 900)
        let offsetWindow = CGRect(x: -1_300, y: -100, width: 1_200, height: 760)
        let focused = CGRect(x: -1_060, y: 540, width: 720, height: 72)
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(
                    text: "副屏输入框里的真实内容",
                    x: 0.40,
                    y: 0.19,
                    width: 0.32,
                    height: 0.03,
                    confidence: 0.97
                )
            ],
            focusedFrame: focused,
            caretFrame: nil,
            windowFrame: offsetWindow,
            displayFrame: display,
            referenceText: "副屏输入框里的真实内容"
        )

        #expect(regions.count == 1)
        #expect((regions.first?.y ?? 0) > 0.80)
        #expect(!regions.contains(where: { $0.y < 0.20 }))
    }

    @Test
    func unanchoredOCRFailsClosed() {
        let regions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: [
                NormalizedOCRLine(text: "页面上任意一句相似文字", x: 0.2, y: 0.5, width: 0.4, height: 0.04)
            ],
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: "页面上任意一句相似文字"
        )

        #expect(regions.isEmpty)
        #expect(ReturnInputCaptureContract.regions(
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: window
        ).isEmpty)
    }
}
