import XCTest
@testable import AgentOneCore

final class BrowserContextURLResolverTests: XCTestCase {
    func testChromeAddressBarWinsOverLinksExposedByPage() {
        let candidates = [
            BrowserAddressBarCandidate(
                role: "AXLink",
                title: "First link in article",
                url: "https://wrong.example/link"
            ),
            BrowserAddressBarCandidate(
                role: "AXTextField",
                description: "Address and search bar",
                value: "arxiv.org/abs/1706.03762"
            )
        ]

        let url = BrowserContextURLResolver.resolve(
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            addressBarCandidates: candidates,
            fallbackURLs: ["https://wrong.example/page"]
        )

        XCTAssertEqual(url?.absoluteString, "https://arxiv.org/abs/1706.03762")
    }

    func testSafariSmartSearchFieldIsRecognized() {
        let url = BrowserContextURLResolver.resolve(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            addressBarCandidates: [
                BrowserAddressBarCandidate(
                    role: "AXTextField",
                    title: "Smart Search Field",
                    value: "https://example.com/paper#methods"
                )
            ]
        )

        // Fragments are not stable reading-session identity and may contain
        // private state, so they are removed before persistence.
        XCTAssertEqual(url?.absoluteString, "https://example.com/paper")
    }

    func testSearchTextDoesNotBecomeAFakePageURL() {
        let url = BrowserContextURLResolver.resolve(
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            addressBarCandidates: [
                BrowserAddressBarCandidate(
                    role: "AXComboBox",
                    description: "Address and search bar",
                    value: "how to recover attention"
                )
            ],
            fallbackURLs: ["https://example.com/current"]
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com/current")
    }

    func testSensitiveQueryItemsAreRemovedButPageIdentityRemains() {
        let url = BrowserContextURLResolver.normalizePageURL(
            "https://example.com/paper?chapter=2&access_token=secret&view=full#section"
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com/paper?chapter=2&view=full")
    }

    func testNonBrowserUsesPageFallbackWithoutAddressBarHeuristics() {
        let url = BrowserContextURLResolver.resolve(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            addressBarCandidates: [
                BrowserAddressBarCandidate(role: "AXTextField", value: "example.com/typed")
            ],
            fallbackURLs: ["https://example.com/document"]
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com/document")
    }
}
