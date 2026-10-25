import Foundation

/// One local privacy boundary shared by Accessibility, OCR and model routing.
/// Discussion *about* passwords or API keys is allowed; actual credential-like
/// material and protected system surfaces are not.
public enum SensitiveContextPolicy {
    public static func isProtectedSurface(
        bundleIdentifier: String?,
        windowTitle: String?,
        focusedRole: String? = nil
    ) -> Bool {
        let haystack = [bundleIdentifier, windowTitle, focusedRole]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let protectedSurfaceTerms = [
            "1password", "bitwarden", "keepass", "password manager",
            "密码管理", "支付密码", "payment password", "checkout",
            "银行卡支付", "bank login", "网银", "axsecuretextfield"
        ]
        return protectedSurfaceTerms.contains { haystack.contains($0) }
    }

    public static func containsActualSecret(_ values: String?...) -> Bool {
        let text = values
            .compactMap { $0 }
            .joined(separator: "\n")
        guard !text.isEmpty else { return false }

        let patterns = [
            #"(?i)\b(?:sk|pk|rk|ak)[-_][A-Za-z0-9_-]{16,}\b"#,
            #"(?i)\bwk_mcp_[A-Za-z0-9_-]{16,}\b"#,
            #"(?i)\bAIza[0-9A-Za-z_-]{20,}\b"#,
            #"(?i)\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)(?:api[_ -]?key|mcp[_ -]?key|access[_ -]?token|authorization(?:\s+参数)?|secret|密钥)\s*[:=：]\s*[^\s]{8,}"#,
            #"(?i)(?:password|密码)\s*[:=：]\s*[^\s]{4,}"#,
            #"(?i)(?:银行卡号|card number)\D{0,8}\d{6,19}"#,
            #"(?i)(?:验证码|one[ -]?time code|\botp\b)\D{0,12}\d{4,8}\b"#,
            #"\b[0-9a-fA-F]{32,}\b"#
        ]
        if patterns.contains(where: {
            guard let expression = try? NSRegularExpression(pattern: $0) else { return true }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
        }) {
            return true
        }

        // Card-like digit runs are blocked only when they pass the checksum,
        // which avoids treating ordinary article numbers as payment data.
        let candidates = text.matches(of: /\b(?:\d[ -]?){13,19}\b/)
        return candidates.contains { match in
            let digits = match.output.filter(\.isNumber).compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && luhnValid(digits)
        }
    }

    private static func luhnValid(_ digits: [Int]) -> Bool {
        guard !digits.allSatisfy({ $0 == digits.first }) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { partial, pair in
            let (index, digit) = pair
            guard index % 2 == 1 else { return partial + digit }
            let doubled = digit * 2
            return partial + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }
}
