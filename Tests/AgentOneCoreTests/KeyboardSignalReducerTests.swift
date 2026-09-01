import Foundation
import Testing
@testable import AgentOneCore

@Suite
struct KeyboardSignalReducerTests {
    @Test
    func testAutorepeatNeverCreatesSemanticSignals() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 1_000)

        #expect(
            reducer.consume(
                .init(timestamp: time, kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: true)
            ) == []
        )
        #expect(
            reducer.consume(
                .init(timestamp: time, kind: .returnKey, isAutorepeat: true)
            ) == []
        )
    }

    @Test
    func testFirstPhysicalKeyEmitsOnlyTypingStarted() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 2_000)

        #expect(
            reducer.consume(
                .init(timestamp: time, kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: false)
            ) == [.typingStarted]
        )
    }

    @Test
    func testTypingProgressIsCoalescedBeforeMainActorDelivery() {
        var reducer = KeyboardSignalReducer(typingSessionGap: 1.5, typingProgressInterval: 0.75)
        let start = Date(timeIntervalSince1970: 3_000)

        #expect(
            reducer.consume(
                .init(timestamp: start, kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: false)
            ) == [.typingStarted]
        )
        for offset in [0.1, 0.2, 0.3, 0.4, 0.5] {
            #expect(
                reducer.consume(
                    .init(
                        timestamp: start.addingTimeInterval(offset),
                        kind: .textInput(estimatedCharacterCount: 1),
                        isAutorepeat: false
                    )
                ) == []
            )
        }
        #expect(
            reducer.consume(
                .init(
                    timestamp: start.addingTimeInterval(0.8),
                    kind: .textInput(estimatedCharacterCount: 1),
                    isAutorepeat: false
                )
            ) == [.typingProgress(estimatedCharacterCount: 7)]
        )
    }

    @Test
    func testOnePhysicalReturnCreatesExactlyOneReturnSignal() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 4_000)

        #expect(
            reducer.consume(
                .init(timestamp: time, kind: .returnKey, isAutorepeat: false)
            ) == [.returnPressed]
        )
        #expect(
            reducer.consume(
                .init(
                    timestamp: time.addingTimeInterval(0.04),
                    kind: .returnKey,
                    isAutorepeat: true
                )
            ) == []
        )
    }

    @Test
    func firstKeyAfterReturnAlwaysStartsFreshTypingBurst() {
        var reducer = KeyboardSignalReducer(typingSessionGap: 1.5)
        let start = Date(timeIntervalSince1970: 4_100)

        #expect(reducer.consume(.init(
            timestamp: start,
            kind: .textInput(estimatedCharacterCount: 1),
            isAutorepeat: false
        )) == [.typingStarted])
        #expect(reducer.consume(.init(
            timestamp: start.addingTimeInterval(0.1),
            kind: .returnKey,
            isAutorepeat: false
        )) == [.returnPressed])
        #expect(reducer.consume(.init(
            timestamp: start.addingTimeInterval(0.2),
            kind: .textInput(estimatedCharacterCount: 1),
            isAutorepeat: false
        )) == [.typingStarted])
    }

    @Test
    func pointerFocusResetStartsFreshTypingBurst() {
        var reducer = KeyboardSignalReducer(typingSessionGap: 1.5)
        let start = Date(timeIntervalSince1970: 4_200)

        #expect(reducer.consume(.init(
            timestamp: start,
            kind: .textInput(estimatedCharacterCount: 1),
            isAutorepeat: false
        )) == [.typingStarted])
        reducer.resetTypingSession()
        #expect(reducer.consume(.init(
            timestamp: start.addingTimeInterval(0.1),
            kind: .textInput(estimatedCharacterCount: 1),
            isAutorepeat: false
        )) == [.typingStarted])
    }

    @Test
    func testDeletionBurstStillRequiresThreePhysicalPresses() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 5_000)

        #expect(
            reducer.consume(
                .init(timestamp: time, kind: .deletionKey, isAutorepeat: false)
            ) == []
        )
        #expect(
            reducer.consume(
                .init(
                    timestamp: time.addingTimeInterval(0.1),
                    kind: .deletionKey,
                    isAutorepeat: false
                )
            ) == []
        )
        #expect(
            reducer.consume(
                .init(
                    timestamp: time.addingTimeInterval(0.2),
                    kind: .deletionKey,
                    isAutorepeat: false
                )
            ) == [.deletionBurst(repeatCount: 3)]
        )
    }
}
