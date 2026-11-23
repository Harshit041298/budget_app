import Foundation

// MARK: - Amounts

public enum AmountParsing {
    /// Parses amounts like `1,234.56`, `$45.00`, `-45.00`, `45.00-`, `(45.00)`,
    /// `45.00 CR`. Returns the magnitude and whether it was marked negative/credit.
    public static func parse(_ raw: String) -> (value: Decimal, negative: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        let upper = s.uppercased()
        if upper.hasSuffix("CR") {
            negative = true
            s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("-") || s.hasPrefix("−") {
            negative = true
            s = String(s.dropFirst())
        }
        if s.hasSuffix("-") {
            negative = true
            s = String(s.dropLast())
        }
        s = s.replacingOccurrences(of: "CAD", with: "")
            .replacingOccurrences(of: "USD", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
        if s.hasPrefix("-") { negative = true; s = String(s.dropFirst()) }
        guard !s.isEmpty,
              s.allSatisfy({ $0.isNumber || $0 == "." }),
              s.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return (value, negative)
    }

    /// Regex fragment matching a money amount with exactly two decimals.
    public static let pattern = #"-?\$?\(?(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\)?-?(?:\s?CR\b)?"#
}

// MARK: - Dates

public enum DateParsing {
    static let posix = Locale(identifier: "en_US_POSIX")

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    public static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static let isoMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthMap: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
        // French (CIBC statements are often bilingual)
        "janv": 1, "fév": 2, "févr": 2, "fev": 2, "avr": 4, "mai": 5, "juin": 6,
        "juil": 7, "aoû": 8, "aou": 8, "août": 8, "sept": 9, "déc": 12
    ]

    /// Month number from tokens like `Oct`, `OCT.`, `October`, `sept`.
    public static func month(from token: String) -> Int? {
        let t = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let m = monthMap[t] { return m }
        if t.count >= 3, let m = monthMap[String(t.prefix(3))] {
            // Guard against random words starting with "mar", "may" etc. by
            // requiring the token to be a plausible month word.
            let full = ["january", "february", "march", "april", "may", "june", "july",
                        "august", "september", "october", "november", "december",
                        "sept", "janvier", "février", "mars", "avril", "juillet",
                        "septembre", "octobre", "novembre", "décembre"]
            if t.count == 3 || full.contains(t) { return m }
        }
        return nil
    }

    public static func make(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return calendar.date(from: c)
    }

    /// Parses common full-date formats: `2026-10-04`, `10/04/2026`,
    /// `Oct 4, 2026`, `4 Oct 2026`, ISO-8601 timestamps.
    public static func parseFullDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // ISO 8601 timestamp, e.g. 2024-01-15T18:22:31Z / .000Z
        if s.count > 10, s.contains("T") {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
        }

        if let m = firstMatch(#"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})"#, in: s),
           let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) {
            return make(year: y, month: mo, day: d)
        }
        if let m = firstMatch(#"^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})"#, in: s),
           let a = Int(m[1]), let b = Int(m[2]), var y = Int(m[3]) {
            if y < 100 { y += 2000 }
            // Assume North American MM/DD unless that is impossible.
            if a > 12 { return make(year: y, month: b, day: a) }
            return make(year: y, month: a, day: b)
        }
        if let m = firstMatch(#"([A-Za-zéû]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})"#, in: s),
           let mo = month(from: m[1]), let d = Int(m[2]), let y = Int(m[3]) {
            return make(year: y, month: mo, day: d)
        }
        if let m = firstMatch(#"(\d{1,2})\s+([A-Za-zéû]{3,9})\.?,?\s+(\d{4})"#, in: s),
           let d = Int(m[1]), let mo = month(from: m[2]), let y = Int(m[3]) {
            return make(year: y, month: mo, day: d)
        }
        return nil
    }

    /// Finds every `Mon DD, YYYY` style date in a block of text.
    public static func allFullDates(in text: String) -> [Date] {
        allMatches(#"([A-Za-zéû]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})"#, in: text).compactMap { m in
            guard let mo = month(from: m[1]), let d = Int(m[2]), let y = Int(m[3]),
                  (2000...2100).contains(y) else { return nil }
            return make(year: y, month: mo, day: d)
        }
    }

    public static func components(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    public static func startOfMonth(_ date: Date) -> Date {
        let c = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: c) ?? date
    }

    public static func addMonths(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: n, to: date) ?? date
    }

    public static func days(from a: Date, to b: Date) -> Double {
        b.timeIntervalSince(a) / 86_400
    }
}

/// Resolves the year for statement lines that only show "Oct 04" by using the
/// statement's closing date.
public struct StatementYearResolver: Sendable {
    public let closingYear: Int
    public let closingMonth: Int

    public init(closingDate: Date) {
        let c = DateParsing.components(closingDate)
        closingYear = c.year
        closingMonth = c.month
    }

    /// Picks the closing date from the latest full date mentioned in the text
    /// (statement period / statement date), falling back to `fallback`.
    public init(text: String, fallback: Date = Date()) {
        let dates = DateParsing.allFullDates(in: text).filter { $0 <= fallback.addingTimeInterval(86_400 * 120) }
        self.init(closingDate: dates.max() ?? fallback)
    }

    public func date(month: Int, day: Int) -> Date? {
        // A December line on a January statement belongs to the prior year.
        let year = month > closingMonth ? closingYear - 1 : closingYear
        return DateParsing.make(year: year, month: month, day: day)
    }
}

// MARK: - Regex helpers

func firstMatch(_ pattern: String, in s: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}

func allMatches(_ pattern: String, in s: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var collapsingWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - CSV

public enum CSV {
    /// RFC-4180-ish CSV parser supporting quoted fields, escaped quotes and
    /// CRLF line endings.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r", "\r\n":
                    row.append(field)
                    field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
