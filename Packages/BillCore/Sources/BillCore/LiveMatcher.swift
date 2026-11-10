import Foundation

/// Matches purchases logged live from Apple Pay to the same purchase when it
/// later appears on an imported statement, so it isn't counted twice.
public enum LiveMatcher {
    public struct Item: Sendable {
        public var id: UUID
        public var date: Date
        public var amount: Double
        public var merchant: String
        public init(id: UUID, date: Date, amount: Double, merchant: String) {
            self.id = id; self.date = date; self.amount = amount; self.merchant = merchant
        }
    }

    /// Returns `[liveID: statementID]`.
    /// - Exact amount: date within -1…+5 days (posting delay).
    /// - Statement up to 30% higher (tip added later): also needs a similar merchant.
    public static func match(live: [Item], statement: [Item]) -> [UUID: UUID] {
        var used = Set<UUID>()
        var result: [UUID: UUID] = [:]
        for l in live.sorted(by: { $0.date < $1.date }) {
            var best: (id: UUID, score: Double)?
            for s in statement where !used.contains(s.id) {
                let days = DateParsing.days(from: l.date, to: s.date)
                guard days >= -1.5 && days <= 5.5 else { continue }
                let exact = abs(s.amount - l.amount) < 0.015
                let tipped = s.amount > l.amount && s.amount <= l.amount * 1.3 && similar(l.merchant, s.merchant)
                guard exact || tipped else { continue }
                // Lower is better: prefer exact amounts, similar names, close dates.
                let score = abs(days) + (exact ? 0 : 3) + (similar(l.merchant, s.merchant) ? 0 : 2)
                if best == nil || score < best!.score { best = (s.id, score) }
            }
            if let best {
                used.insert(best.id)
                result[l.id] = best.id
            }
        }
        return result
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let ka = MerchantNormalizer.key(for: MerchantNormalizer.normalize(a))
        let kb = MerchantNormalizer.key(for: MerchantNormalizer.normalize(b))
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        let n = min(5, ka.count, kb.count)
        return ka.hasPrefix(kb.prefix(n)) || kb.hasPrefix(ka.prefix(n))
    }

    /// Extracts the money amount from Shortcuts' text. Works for a bare amount
    /// ("CA$4.50", "$1,234.00", "4,50 $", "4.5") and for a whole transaction
    /// description ("Tim Hortons, $4.50, CIBC Visa") by preferring numbers that
    /// look like money (currency symbol or two decimals) over other digits.
    public static func parseAmount(_ raw: String) -> Double? {
        var s = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        // "4,50" (comma decimal) → "4.50" when there is no dot.
        if !s.contains("."), let m = firstMatch(#"(\d+),(\d{2})\b"#, in: s) {
            s = s.replacingOccurrences(of: m[0], with: "\(m[1]).\(m[2])")
        }
        func num(_ t: String) -> Double? { Double(t.replacingOccurrences(of: ",", with: "")) }
        // 1. Next to a currency symbol/code: $4.50, CA$ 4.50, 4.50 $, CAD 4.50
        if let m = firstMatch(#"(?:[$€£]|CAD|USD)\s?(\d[\d,]*(?:\.\d{1,2})?)"#, in: s), let v = num(m[1]) { return v }
        if let m = firstMatch(#"(\d[\d,]*(?:\.\d{1,2})?)\s?(?:[$€£]|CAD|USD)"#, in: s), let v = num(m[1]) { return v }
        // 2. A number with exactly two decimals.
        if let m = firstMatch(#"\d[\d,]*\.\d{2}\b"#, in: s), let v = num(m[0]) { return v }
        // 3. A bare number (only when the text is basically just a number).
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = firstMatch(#"^\d[\d,]*(?:\.\d+)?$"#, in: trimmed), let v = num(m[0]) { return v }
        return nil
    }
}
