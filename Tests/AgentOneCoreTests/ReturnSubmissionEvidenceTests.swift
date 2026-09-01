import Foundation
import Testing
@testable import AgentOneCore

@Suite
struct ReturnSubmissionEvidenceTests {
    @Test
    func preSubmissionEditorProofWinsOverPostSubmissionHistory() {
        let submitted = "AGENTONE_WECHAT_RETURN_20260812_01"
        let selected = ReturnSubmissionEvidenceSelector.select(
            [
                ReturnSubmissionEvidenceCandidate(
                    id: 1,
                    phase: .postSubmission,
                    recognizedText: "15:54\nMonthly Pulse 已开启\n历史图片",
                    submittedText: "Monthly Pulse 已开启"
                ),
                ReturnSubmissionEvidenceCandidate(
                    id: 2,
                    phase: .preSubmission,
                    recognizedText: submitted,
                    submittedText: submitted
                )
            ],
            referenceText: submitted
        )

        #expect(selected?.id == 2)
    }

    @Test
    func unrelatedPreSubmissionFrameCannotOverrideMatchingFallback() {
        let submitted = "AGENTONE_CODEX_RETURN_20260812_02"
        let selected = ReturnSubmissionEvidenceSelector.select(
            [
                ReturnSubmissionEvidenceCandidate(
                    id: 1,
                    phase: .preSubmission,
                    recognizedText: "5.6 S\n完全访问",
                    submittedText: "5.6 S"
                ),
                ReturnSubmissionEvidenceCandidate(
                    id: 2,
                    phase: .postSubmission,
                    recognizedText: submitted,
                    submittedText: submitted
                )
            ],
            referenceText: submitted
        )

        #expect(selected?.id == 2)
    }

    @Test
    func clearedPreSubmissionFrameFallsBackInsteadOfBecomingFalseProof() {
        let submitted = "AGENTONE_FEISHU_RETURN_20260812_03"
        let selected = ReturnSubmissionEvidenceSelector.select(
            [
                ReturnSubmissionEvidenceCandidate(
                    id: 1,
                    phase: .preSubmission,
                    recognizedText: nil,
                    submittedText: nil
                ),
                ReturnSubmissionEvidenceCandidate(
                    id: 2,
                    phase: .postSubmission,
                    recognizedText: submitted,
                    submittedText: submitted
                )
            ],
            referenceText: submitted
        )

        #expect(selected?.id == 2)
    }

    @Test
    func preSubmissionTextIsUsableWhenElectronExposesNoAXDraft() {
        let submitted = "连续第二条无需重新点击输入框"
        let selected = ReturnSubmissionEvidenceSelector.select(
            [
                ReturnSubmissionEvidenceCandidate(
                    id: 1,
                    phase: .preSubmission,
                    recognizedText: submitted,
                    submittedText: submitted
                ),
                ReturnSubmissionEvidenceCandidate(
                    id: 2,
                    phase: .postSubmission,
                    recognizedText: "历史消息和侧栏",
                    submittedText: "历史消息和侧栏"
                )
            ],
            referenceText: nil
        )

        #expect(selected?.id == 1)
    }

    @Test
    func interfaceChromeAloneCannotBecomePreSubmissionEvidence() {
        #expect(!ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
            evidenceText: "你正在共享屏幕\n5.6 S\n完全访问",
            referenceText: nil
        ))
        #expect(!ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
            evidenceText: "screen sharing\nGPT-5 Auto\nusage: 14%",
            referenceText: nil
        ))
    }

    @Test
    func threeCharacterComposerTextIsValidWithoutAXDraft() {
        #expect(ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
            evidenceText: "继续修",
            referenceText: nil
        ))
        #expect(!ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
            evidenceText: "继续",
            referenceText: nil
        ))
    }

    @Test
    func delayedPostReturnCallbackCannotReplaceThePresentedDraftFrame() {
        let returnAt = Date(timeIntervalSince1970: 100)
        let timestamps = [
            returnAt.addingTimeInterval(-0.18),
            returnAt.addingTimeInterval(-0.03),
            returnAt.addingTimeInterval(0.02)
        ]

        let selected = ReturnSubmissionFrameSelector.latestEligibleIndex(
            in: timestamps,
            returnTimestamp: returnAt,
            notBefore: returnAt.addingTimeInterval(-1)
        )

        #expect(selected == 1)
    }

    @Test
    func frameFromPreviousSubmissionCannotBeReused() {
        let returnAt = Date(timeIntervalSince1970: 100)
        let timestamps = [
            returnAt.addingTimeInterval(-0.60),
            returnAt.addingTimeInterval(-0.08)
        ]

        let selected = ReturnSubmissionFrameSelector.latestEligibleIndex(
            in: timestamps,
            returnTimestamp: returnAt,
            notBefore: returnAt.addingTimeInterval(-0.20)
        )

        #expect(selected == 1)
    }
}
