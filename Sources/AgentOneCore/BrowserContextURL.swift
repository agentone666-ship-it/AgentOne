import Foundation

/// A small, platform-neutral representation of an Accessibility control that
/// may be a browser address bar. Keeping this value type in Core makes the
/// URL decision testable without needing a live Chrome/Safari Accessibility
/// tree.
public struct BrowserAddressBarCandidate: Hashable, Sendable {
    public var role: String?
    public var title: String?
    public var description: String?
    public var identifier: String?
    public var value: String?
    public var url: String?

    public init(
        role: String? = nil,
        title: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        url: String? = nil
    ) {
        self.role = role
        self.title = title
        self.description = description
        self.identifier = identifier
        self.value = value
        self.url = url
    }
}

/// Resolves the page the user is reading from the browser's address/search
/// field. Page Accessibility trees contain many links; using the first AXURL
/// is therefore not a reliable way to identify the current page. The address
/// bar is authoritative, with an AXURL/document fallback for browsers that do
/// not expose the bar to the current Accessibility client.
public enum BrowserContextURLResolver {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.microsoft.edgemac",
        "com.apple.safari",
        "org.mozilla.firefox",
        "company.thebrowser.browser", // Arc
        "com.brave.browser",
        "com.operasoftware.opera"
    ]

    private static let browserNames: Set<String> = [
        "chrome", "google chrome", "safari", "microsoft edge", "edge",
        "firefox", "arc", "brave browser", "brave", "opera"
    ]

    private static let addressBarTerms = [
        "address and search", "address bar", "omnibox", "location bar",
        "smart search", "search field", "search or enter address",
        "search with google or enter address", "url bar", "address",
        "地址栏", "地址和搜索栏", "智能搜索", "智能搜索栏", "搜索栏",
        "搜索或输入网址", "搜索网页或输入网址", "网址"
    ]

    private static let sensitiveQueryTerms = [
        "token", "access_token", "refresh_token", "id_token", "auth",
        "authorization", "api_key", "apikey", "secret", "password", "passwd",
        "session", "sessionid", "jwt", "signature", "sig", "code", "state",
        "nonce", "otp", "verification", "验证码", "密钥", "密码"
    ]

    /// Returns a normalized, privacy-clean URL. Search terms and arbitrary
    /// text are deliberately rejected; a browser address field containing a
    /// search query must not become a fake page URL in the diary.
    public static func resolve(
        bundleIdentifier: String?,
        applicationName: String?,
        addressBarCandidates: [BrowserAddressBarCandidate],
        fallbackURLs: [String?] = []
    ) -> URL? {
        guard isBrowser(bundleIdentifier: bundleIdentifier, applicationName: applicationName) else {
            return firstPageURL(in: fallbackURLs)
        }

        let ranked = addressBarCandidates
            .enumerated()
            .map { index, candidate in (score(candidate), index, candidate) }
            .sorted {
                if $0.0 == $1.0 { return $0.1 < $1.1 }
                return $0.0 > $1.0
            }

        for (score, _, candidate) in ranked where score > 0 {
            for raw in [candidate.url, candidate.value, candidate.title].compactMap({ $0 }) {
                if let url = normalizePageURL(raw) { return url }
            }
        }

        return firstPageURL(in: fallbackURLs)
    }

    public static func isBrowser(bundleIdentifier: String?, applicationName: String?) -> Bool {
        let bundle = bundleIdentifier?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundle, browserBundleIdentifiers.contains(bundle) { return true }
        let name = applicationName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.map { browserNames.contains($0) } ?? false
    }

    /// Exposed for interface-level tests and callers that need to normalize a
    /// URL obtained from AXDocument/AXURL.
    public static func normalizePageURL(_ raw: String) -> URL? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096 else { return nil }
        guard trimmed.range(of: "\\s", options: .regularExpression) == nil else { return nil }

        let candidate: String
        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            candidate = trimmed
        } else if isBareDomainOrPath(trimmed) {
            candidate = "https://\(trimmed)"
        } else {
            return nil
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              !host.contains(" ") else {
            return nil
        }

        // Never persist credentials, OAuth state, API keys, session tokens or
        // payment/verification parameters from an address bar URL.
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.filter {
                !isSensitiveQueryName($0.name)
            }
        }
        return components.url
    }

    private static func firstPageURL(in values: [String?]) -> URL? {
        values.compactMap { $0 }.lazy.compactMap(normalizePageURL).first
    }

    private static func score(_ candidate: BrowserAddressBarCandidate) -> Int {
        let role = candidate.role?.lowercased() ?? ""
        let metadata = [candidate.title, candidate.description, candidate.identifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let hasSemanticMarker = addressBarTerms.contains(where: { metadata.contains($0) })
            || candidate.identifier?.lowercased().contains("address") == true
            || candidate.identifier?.lowercased().contains("url") == true
        guard hasSemanticMarker else { return 0 }
        var value = 0
        if role == "axtextfield" { value += 2 }
        if role == "axcombobox" { value += 2 }
        if role == "axsearchfield" { value += 1 }
        if addressBarTerms.contains(where: { metadata.contains($0) }) { value += 8 }
        if candidate.identifier?.lowercased().contains("address") == true
            || candidate.identifier?.lowercased().contains("url") == true {
            value += 5
        }
        return value
    }

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "[-.]", with: "_", options: .regularExpression)
        if normalized == "key" || normalized.hasSuffix("_key") {
            return true
        }
        return sensitiveQueryTerms.contains { term in
            normalized == term || normalized.contains(term)
        }
    }

    private static func isBareDomainOrPath(_ value: String) -> Bool {
        guard !value.contains(" "), !value.contains("\\"), !value.hasPrefix("/") else { return false }
        let authority = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if host.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil {
            return true
        }
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
}
