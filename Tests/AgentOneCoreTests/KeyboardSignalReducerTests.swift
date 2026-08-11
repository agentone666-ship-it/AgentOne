import XCTest
@testable import AgentOneCore

final class KeyboardSignalReducerTests: XCTestCase {
    func testAutorepeatNeverCreatesSemanticSignals() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            reducer.consume(.init(timestamp: time, kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: true)),
            []
        )
        XCTAssertEqual(
            reducer.consume(.init(timestamp: time, kind: .returnKey, isAutorepeat: true)),
            []
        )
    }

    func testFirstPhysicalKeyEmitsOnlyTypingStarted() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(
            reducer.consume(.init(timestamp: time, kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: false)),
            [.typingStarted]
        )
    }

    func testTypingProgressIsCoalescedBeforeMainActorDelivery() {
        var reducer = KeyboardSignalReducer(typingSessionGap: 1.5, typingProgressInterval: 0.75)
        let start = Date(timeIntervalSince1970: 3_000)

        XCTAssertEqual(
            reducer.consume(.init(timestamp: start, kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: false)),
            [.typingStarted]
        )
        for offset in [0.1, 0.2, 0.3, 0.4, 0.5] {
            XCTAssertEqual(
                reducer.consume(.init(timestamp: start.addingTimeInterval(offset), kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: false)),
                []
            )
        }
        XCTAssertEqual(
            reducer.consume(.init(timestamp: start.addingTimeInterval(0.8), kind: .textInput(estimatedCharacterCount: 1), isAutorepeat: false)),
            [.typingProgress(estimatedCharacterCount: 7)]
        )
    }

    func testOnePhysicalReturnCreatesExactlyOneReturnSignal() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 4_000)

        XCTAssertEqual(
            reducer.consume(.init(timestamp: time, kind: .returnKey, isAutorepeat: false)),
            [.returnPressed]
        )
        XCTAssertEqual(
            reducer.consume(.init(timestamp: time.addingTimeInterval(0.04), kind: .returnKey, isAutorepeat: true)),
            []
        )
    }

    func testDeletionBurstStillRequiresThreePhysicalPresses() {
        var reducer = KeyboardSignalReducer()
        let time = Date(timeIntervalSince1970: 5_000)

        XCTAssertEqual(reducer.consume(.init(timestamp: time, kind: .deletionKey, isAutorepeat: false)), [])
        XCTAssertEqual(reducer.consume(.init(timestamp: time.addingTimeInterval(0.1), kind: .deletionKey, isAutorepeat: false)), [])
        XCTAssertEqual(
            reducer.consume(.init(timestamp: time.addingTimeInterval(0.2), kind: .deletionKey, isAutorepeat: false)),
            [.deletionBurst(repeatCount: 3)]
        )
    }
}
