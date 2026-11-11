import Foundation

/// Removes security-sensitive details from text before it is stored or shown
/// to a cloud model: card numbers, bank account / transit numbers, SINs, phone
/// numbers, emails and postal codes. Statements are parsed from the original
/// text in memory first; only the redacted form is ever saved.
public enum Redactor {
    struct Rule { let pattern: String; let replace: (String) -> String }

    static func last(_ n: Int, digitsOf s: String) -> String {
        String(s.filter(\.isNumber).suffix(n))
    }

    static let rules: [Rule] = [
        // Masked cards as printed on statements: 4500 **** **** 1234, 4500********1234, XXXX XXXX XXXX 1234
        Rule(pattern: #"\b\d{4}[\s-]?(?:[X\*•]{4}[\s-]?){2}\d{4}\b|\b(?:[X\*•]{4}[\s-]?){3}\d{4}\b"#,
             replace: { "card ••" + last(4, digitsOf: $0) }),
        // Full card numbers: 4 groups of digits, or 13-19 digits in a row
        Rule(pattern: #"\b\d{4}[\s-]\d{4}[\s-]\d{4}[\s-]\d{1,7}\b|\b\d{13,19}\b"#,
             replace: { "card ••" + last(4, digitsOf: $0) }),
        // Labelled account / transit / institution / reference numbers
        Rule(pattern: #"(?i)\b(account|acct|a/c|transit|institution|branch|member|customer|client|reference|ref)\b\.?\s*(?:no\.?|number|num|#|id)?\s*[:#]?\s*[\d][\d\s-]{3,}\d"#,
             replace: { match in
                 let label = match.prefix { !$0.isNumber }.trimmingCharacters(in: .whitespaces)
                 return "\(label) ••" + last(3, digitsOf: match)
             }),
        // Social Insurance Number
        Rule(pattern: #"\b\d{3}[\s-]\d{3}[\s-]\d{3}\b"#, replace: { _ in "[SIN removed]" }),
        // Phone numbers
        Rule(pattern: #"(?:\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b"#, replace: { _ in "[phone]" }),
        // Email
        Rule(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, replace: { _ in "[email]" }),
        // Canadian postal code
        Rule(pattern: #"\b[ABCEGHJ-NPRSTVXY]\d[A-Z][\s-]?\d[A-Z]\d\b"#, replace: { _ in "[postal code]" }),
        // Any other long digit run (7+ digits, e.g. account or reference numbers)
        Rule(pattern: #"\b\d{7,}\b"#, replace: { "••" + last(3, digitsOf: $0) })
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let original = ns.substring(with: m.range)
                out = (out as NSString).replacingCharacters(in: m.range, with: rule.replace(original))
            }
        }
        return out
    }

    /// Stricter form for anything sent to a cloud model: also hides the last
    /// digits of card / account references.
    public static func forCloud(_ text: String) -> String {
        redact(text)
            .replacingOccurrences(of: #"••\s?\d{2,4}"#, with: "••", options: .regularExpression)
    }
}
