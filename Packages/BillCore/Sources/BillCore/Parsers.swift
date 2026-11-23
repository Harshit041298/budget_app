import Foundation

// MARK: - CIBC CSV (online banking "Download transactions")

/// CIBC exports CSV without a header:
/// `2026-10-04,TIM HORTONS #2345 TORONTO ON,4.50,,4500********1234`
/// Columns: date, description, debit, credit, [card number for credit cards].
public enum CIBCCSVParser {
    public static func canParse(_ rows: [[String]]) -> Bool {
        let sample = rows.prefix(10)
        let hits = sample.filter { row in
            row.count >= 3
                && firstMatch(#"^\d{4}-\d{2}-\d{2}$"#, in: row[0].trimmed) != nil
                && (AmountParsing.parse(row[2]) != nil || (row.count > 3 && AmountParsing.parse(row[3]) != nil))
        }
        return !hits.isEmpty && hits.count >= sample.count / 2
    }

    public static func parse(_ rows: [[String]]) -> ParseResult {
        var out: [ParsedTransaction] = []
        var warnings: [String] = []
        for (i, row) in rows.enumerated() {
            guard row.count >= 3, let date = DateParsing.parseFullDate(row[0]) else {
                if i > 0 { warnings.append("Skipped row \(i + 1)") }
                continue
            }
            let desc = row[1].collapsingWhitespace
            let debit = AmountParsing.parse(row[2])
            let credit = row.count > 3 ? AmountParsing.parse(row[3]) : nil
            var account: String?
            if row.count > 4 {
                let digits = row[4].filter(\.isNumber)
                if digits.count >= 4 { account = "Card ••\(digits.suffix(4))" }
            }
            if let d = debit, d.value != 0 {
                out.append(ParsedTransaction(date: date, rawDescription: desc, amount: d.value,
                                             isCredit: d.negative, account: account))
            } else if let c = credit, c.value != 0 {
                out.append(ParsedTransaction(date: date, rawDescription: desc, amount: c.value,
                                             isCredit: !c.negative, account: account))
            }
        }
        return ParseResult(kind: .cibcCSV, transactions: out, warnings: warnings)
    }
}

// MARK: - Generic bank CSV with a header row

public enum GenericCSVParser {
    struct Columns {
        var date: Int
        var description: Int
        var amount: Int?
        var debit: Int?
        var credit: Int?
    }

    static func columns(for header: [String]) -> Columns? {
        let h = header.map { $0.lowercased().trimmed }
        func find(_ keys: [String]) -> Int? {
            h.firstIndex { col in keys.contains { col.contains($0) } }
        }
        guard let date = find(["date", "posted"]),
              let desc = find(["description", "merchant", "payee", "details", "name", "memo"])
        else { return nil }
        let amount = find(["amount", "montant"])
        let debit = find(["debit", "withdrawal", "withdrawn", "money out"])
        let credit = find(["credit", "deposit", "money in"])
        guard amount != nil || debit != nil || credit != nil else { return nil }
        return Columns(date: date, description: desc, amount: amount, debit: debit, credit: credit)
    }

    public static func canParse(_ rows: [[String]]) -> Bool {
        guard let header = rows.first else { return false }
        return columns(for: header) != nil
    }

    public static func parse(_ rows: [[String]]) -> ParseResult {
        guard let header = rows.first, let cols = columns(for: header) else {
            return ParseResult(kind: .genericCSV, transactions: [])
        }
        var out: [ParsedTransaction] = []
        for row in rows.dropFirst() {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            guard let date = DateParsing.parseFullDate(cell(cols.date)) else { continue }
            let desc = cell(cols.description).collapsingWhitespace
            if cols.debit != nil || cols.credit != nil,
               AmountParsing.parse(cell(cols.debit)) != nil || AmountParsing.parse(cell(cols.credit)) != nil {
                if let d = AmountParsing.parse(cell(cols.debit)), d.value != 0 {
                    out.append(ParsedTransaction(date: date, rawDescription: desc, amount: d.value, isCredit: d.negative))
                } else if let c = AmountParsing.parse(cell(cols.credit)), c.value != 0 {
                    out.append(ParsedTransaction(date: date, rawDescription: desc, amount: c.value, isCredit: !c.negative))
                }
            } else if let a = AmountParsing.parse(cell(cols.amount)), a.value != 0 {
                // Convention: negative = money out.
                out.append(ParsedTransaction(date: date, rawDescription: desc, amount: a.value, isCredit: !a.negative))
            }
        }
        return ParseResult(kind: .genericCSV, transactions: out)
    }
}

// MARK: - Amazon order history

/// Parses Amazon's "Request Your Data" export (`Retail.OrderHistory.1.csv`)
/// and the older "Order History Report" CSV. One transaction per order, with
/// product names as line items.
public enum AmazonOrderParser {
    public static func canParse(_ rows: [[String]]) -> Bool {
        guard let header = rows.first?.map({ $0.lowercased().trimmed }) else { return false }
        return header.contains("order id") && (header.contains("product name") || header.contains("title"))
    }

    public static func parse(_ rows: [[String]]) -> ParseResult {
        guard let header = rows.first?.map({ $0.lowercased().trimmed }) else {
            return ParseResult(kind: .amazonOrderHistory, transactions: [])
        }
        func idx(_ names: [String]) -> Int? {
            for n in names { if let i = header.firstIndex(of: n) { return i } }
            return nil
        }
        guard let orderIdx = idx(["order id"]),
              let dateIdx = idx(["order date"]),
              let nameIdx = idx(["product name", "title"]),
              let totalIdx = idx(["total owed", "item total", "total charged"])
        else {
            return ParseResult(kind: .amazonOrderHistory, transactions: [],
                               warnings: ["Amazon file is missing expected columns"])
        }
        let statusIdx = idx(["order status"])
        let qtyIdx = idx(["quantity"])
        let currencyIdx = idx(["currency"])
        let websiteIdx = idx(["website"])

        struct Order { var date: Date; var total: Decimal; var items: [String]; var site: String }
        var orders: [String: Order] = [:]
        var order: [String] = []

        for row in rows.dropFirst() {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0].trimmed : nil } ?? "" }
            let id = cell(orderIdx)
            guard !id.isEmpty, let date = DateParsing.parseFullDate(cell(dateIdx)) else { continue }
            if cell(statusIdx).lowercased().contains("cancel") { continue }
            let total = AmountParsing.parse(cell(totalIdx))?.value ?? 0
            var name = cell(nameIdx).collapsingWhitespace
            if name.count > 90 { name = String(name.prefix(87)) + "…" }
            if let q = Int(cell(qtyIdx)), q > 1 { name = "\(q)× \(name)" }
            let currency = cell(currencyIdx)
            let site = cell(websiteIdx).isEmpty ? (currency.isEmpty ? "Amazon" : "Amazon (\(currency))") : cell(websiteIdx)
            if orders[id] == nil {
                orders[id] = Order(date: date, total: 0, items: [], site: site)
                order.append(id)
            }
            orders[id]!.total += total
            if !name.isEmpty { orders[id]!.items.append(name) }
        }

        let txns = order.compactMap { id -> ParsedTransaction? in
            guard let o = orders[id], o.total > 0 else { return nil }
            return ParsedTransaction(date: o.date, rawDescription: "AMAZON ORDER \(id)", amount: o.total,
                                     isCredit: false, categoryHint: .shopping, account: o.site,
                                     items: o.items, externalID: "amazon:\(id)")
        }
        return ParseResult(kind: .amazonOrderHistory, transactions: txns)
    }
}

// MARK: - CIBC credit card statement (PDF text)

/// CIBC Visa/Mastercard statements list charges as:
/// `Sep 28 Sep 30 AMAZON.CA*AB12CD AMAZON.CA ON Retail and Grocery 45.67`
/// (transaction date, posting date, description, spend category, amount).
public enum CIBCCreditCardStatementParser {
    static let cibcLabels = [
        "Retail and Grocery", "Restaurants", "Transportation", "Hotel, Entertainment and Recreation",
        "Health and Education", "Home and Office Improvement", "Personal and Household Expenses",
        "Professional and Financial Services", "Foreign Currency Transactions", "Hotel, Entertainment and Rec"
    ]

    static let linePattern = #"^([A-Za-zéû]{3,4})\.?\s+(\d{1,2})\s+([A-Za-zéû]{3,4})\.?\s+(\d{1,2})\s+(.+?)\s+("# + AmountParsing.pattern + #")\s*$"#

    public static func looksLike(_ text: String) -> Bool {
        let l = text.lowercased()
        let cardWords = l.contains("visa") || l.contains("mastercard") || l.contains("credit card")
            || l.contains("spend categories") || l.contains("minimum payment")
        return cardWords && matchCount(text) >= 1
    }

    static func matchCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines).filter { firstMatch(linePattern, in: $0.trimmed) != nil }.count
    }

    public static func parse(_ text: String, now: Date = Date()) -> ParseResult {
        let resolver = StatementYearResolver(text: text, fallback: now)
        var out: [ParsedTransaction] = []
        var inPayments = false
        let account = firstMatch(#"(\d{4})\s*[X\*•]{4}\s*[X\*•]{4}\s*(\d{4})"#, in: text).map { "Card ••\($0[2])" }
            ?? firstMatch(#"[X\*•]{4}\s*(\d{4})\b"#, in: text).map { "Card ••\($0[1])" }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.collapsingWhitespace
            let lower = line.lowercased()
            if lower.contains("your payments") || lower.contains("vos paiements") { inPayments = true; continue }
            if lower.contains("your new charges") || lower.contains("vos nouveaux") { inPayments = false; continue }

            guard let m = firstMatch(linePattern, in: line),
                  let month = DateParsing.month(from: m[1]),
                  let day = Int(m[2]),
                  let date = resolver.date(month: month, day: day),
                  let amt = AmountParsing.parse(m[6])
            else { continue }

            var desc = m[5]
            var hint: SpendCategory?
            for label in cibcLabels where desc.hasSuffix(label) {
                hint = RuleCategorizer.fromCIBCLabel(label)
                desc = String(desc.dropLast(label.count)).trimmed
                break
            }
            let isPayment = desc.uppercased().contains("PAYMENT THANK YOU") || desc.uppercased().contains("PAIEMENT MERCI")
            let isCredit = amt.negative || inPayments || isPayment
            out.append(ParsedTransaction(date: date, rawDescription: desc, amount: amt.value, isCredit: isCredit,
                                         categoryHint: isPayment ? .transfer : hint, account: account))
        }
        return ParseResult(kind: .cibcCreditCardStatement, transactions: out)
    }
}

// MARK: - CIBC chequing / savings statement (PDF text)

/// CIBC bank statements look like:
/// ```
/// Date  Description                 Withdrawals ($)  Deposits ($)  Balance ($)
/// Oct 1 Opening balance                                           2,500.00
/// Oct 3 POINT OF SALE PURCHASE
///       TIM HORTONS #2345            4.50
///       E-TRANSFER 1234 JOHN                         100.00        2,595.50
/// ```
/// Text extraction loses the column positions, so we can't tell withdrawals
/// from deposits by position. Instead we use the running balance: the signed
/// amounts between two balances must add up to the balance change, and we
/// pick the sign assignment that satisfies that (breaking ties with keywords).
public enum CIBCBankStatementParser {
    static let amountRe = AmountParsing.pattern
    static let trailingAmounts = #"^(.*?)\s*("# + amountRe + #")(?:\s+("# + amountRe + #"))?\s*$"#
    static let leadingDate = #"^([A-Za-zéû]{3,4})\.?\s+(\d{1,2})\s+(.*)$"#

    public static func looksLike(_ text: String) -> Bool {
        let l = text.lowercased()
        return (l.contains("withdrawals") && l.contains("deposits")) || l.contains("opening balance")
            || (l.contains("retraits") && l.contains("dépôts"))
    }

    static let skipPhrases = ["page ", "date description", "withdrawals", "account summary", "account statement",
                              "transaction details", "continued", "balance forward", "important:", "cibc.com",
                              "total withdrawals", "total deposits", "closing balance", "opening balance"]

    struct Pending {
        var date: Date
        var description: String
        var amount: Decimal
    }

    public static func parse(_ text: String, now: Date = Date()) -> ParseResult {
        let resolver = StatementYearResolver(text: text, fallback: now)
        var out: [ParsedTransaction] = []
        var warnings: [String] = []
        var currentDate: Date?
        var balance: Decimal?
        var descBuffer: [String] = []
        var pending: [Pending] = []

        func flush(newBalance: Decimal?) {
            guard !pending.isEmpty else { return }
            let signs: [Bool]   // true = credit
            if let newBalance, let old = balance {
                signs = solveSigns(pending.map(\.amount), delta: newBalance - old,
                                   preferred: pending.map { guessCredit($0.description) })
                    ?? pending.map { guessCredit($0.description) }
            } else {
                signs = pending.map { guessCredit($0.description) }
                warnings.append("Guessed direction for \(pending.count) transaction(s) without a running balance")
            }
            for (p, credit) in zip(pending, signs) {
                out.append(ParsedTransaction(date: p.date, rawDescription: p.description, amount: p.amount, isCredit: credit))
            }
            pending.removeAll()
        }

        for raw in text.components(separatedBy: .newlines) {
            var line = raw.collapsingWhitespace
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if let m = firstMatch(leadingDate, in: line), let mo = DateParsing.month(from: m[1]), let d = Int(m[2]),
               let date = resolver.date(month: mo, day: d) {
                currentDate = date
                line = m[3]
            }

            if lower.contains("opening balance") || lower.contains("balance forward") || lower.contains("solde d'ouverture") {
                if let m = firstMatch(#"("# + amountRe + #")\s*$"#, in: line), let a = AmountParsing.parse(m[1]) {
                    balance = a.negative ? -a.value : a.value
                }
                descBuffer.removeAll()
                continue
            }
            if lower.contains("closing balance") {
                if let m = firstMatch(#"("# + amountRe + #")\s*$"#, in: line), let a = AmountParsing.parse(m[1]) {
                    flush(newBalance: a.negative ? -a.value : a.value)
                    balance = a.negative ? -a.value : a.value
                }
                descBuffer.removeAll()
                continue
            }

            guard let date = currentDate else { continue }

            if let m = firstMatch(trailingAmounts, in: line), let a1 = AmountParsing.parse(m[2]) {
                let desc = (descBuffer + [m[1]]).joined(separator: " ").collapsingWhitespace
                descBuffer.removeAll()
                if desc.isEmpty || skipPhrases.contains(where: { desc.lowercased().hasPrefix($0) }) { continue }
                pending.append(Pending(date: date, description: desc, amount: a1.value))
                if !m[3].isEmpty, let bal = AmountParsing.parse(m[3]) {
                    let newBal = bal.negative ? -bal.value : bal.value
                    flush(newBalance: newBal)
                    balance = newBal
                }
            } else if !skipPhrases.contains(where: { lower.hasPrefix($0) }), line.contains(where: \.isLetter) {
                descBuffer.append(line)
                if descBuffer.count > 3 { descBuffer.removeFirst() }
            }
        }
        flush(newBalance: nil)
        return ParseResult(kind: .cibcBankStatement, transactions: out, warnings: warnings)
    }

    static func guessCredit(_ desc: String) -> Bool {
        let u = desc.uppercased()
        let creditWords = ["DEPOSIT", "PAYROLL", "E-TRANSFER RECEIVED", "INTERAC E-TRANSFER FROM", "REFUND", "REBATE",
                           "INTEREST PAID", "TRANSFER FROM", "CREDIT MEMO", "REVERSAL", "GST", "CANADA", "SALARY"]
        return creditWords.contains { u.contains($0) }
    }

    /// Finds credit/debit flags for `amounts` such that
    /// sum(credits) - sum(debits) == delta, preferring `preferred`.
    static func solveSigns(_ amounts: [Decimal], delta: Decimal, preferred: [Bool]) -> [Bool]? {
        let n = amounts.count
        guard n > 0, n <= 16 else { return nil }
        var best: [Bool]?
        var bestCost = Int.max
        for mask in 0..<(1 << n) {
            var sum: Decimal = 0
            for i in 0..<n { sum += (mask >> i) & 1 == 1 ? amounts[i] : -amounts[i] }
            let diff = sum - delta
            guard diff < 0.006 && diff > -0.006 else { continue }
            var cost = 0
            for i in 0..<n where ((mask >> i) & 1 == 1) != preferred[i] { cost += 1 }
            if cost < bestCost {
                bestCost = cost
                best = (0..<n).map { (mask >> $0) & 1 == 1 }
            }
        }
        return best
    }
}

// MARK: - Receipts & bills (heuristic, used when the on-device LLM is unavailable)

public enum ReceiptHeuristicParser {
    public static func parse(_ text: String, now: Date = Date()) -> ParseResult {
        let lines = text.components(separatedBy: .newlines).map(\.collapsingWhitespace).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ParseResult(kind: .receipt, transactions: []) }

        let noise = ["receipt", "invoice", "welcome", "thank", "store", "tel", "phone", "www", "http", "gst", "hst", "order"]
        let merchant = lines.prefix(6).first { l in
            let low = l.lowercased()
            return l.filter(\.isLetter).count >= 3 && !noise.contains(where: { low.hasPrefix($0) })
                && firstMatch(AmountParsing.pattern, in: l) == nil
        } ?? "Receipt"

        // Prefer an explicit total line; bills often say "Amount due" / "Total due".
        let totalKeys = ["amount due", "total due", "balance due", "new balance", "grand total", "total amount",
                         "amount paid", "total", "montant dû", "total à payer"]
        var total: Decimal?
        for key in totalKeys {
            let candidates = lines.filter { l in
                let low = l.lowercased()
                return low.contains(key) && !low.contains("subtotal") && !low.contains("sub-total") && !low.contains("sous-total")
            }
            let amounts = candidates.compactMap { l -> Decimal? in
                allMatches(AmountParsing.pattern, in: l).last.flatMap { AmountParsing.parse($0[0])?.value }
            }
            if let maxAmt = amounts.max() { total = maxAmt; break }
        }
        if total == nil {
            total = allMatches(AmountParsing.pattern, in: text).compactMap { AmountParsing.parse($0[0])?.value }.max()
        }

        var date: Date?
        let datePatterns = [#"\d{4}[-/]\d{1,2}[-/]\d{1,2}"#, #"\d{1,2}/\d{1,2}/\d{2,4}"#,
                            #"[A-Za-z]{3,9}\.?\s+\d{1,2},?\s+\d{4}"#, #"\d{1,2}\s+[A-Za-z]{3,9}\.?\s+\d{4}"#]
        outer: for line in lines {
            for p in datePatterns {
                if let m = firstMatch(p, in: line), let d = DateParsing.parseFullDate(m[0]), d <= now.addingTimeInterval(86_400 * 60) {
                    date = d
                    break outer
                }
            }
        }

        guard let total, total > 0 else {
            return ParseResult(kind: .receipt, transactions: [], warnings: ["Couldn't find a total"])
        }
        let txn = ParsedTransaction(date: date ?? now, rawDescription: merchant, amount: total, isCredit: false,
                                    categoryHint: RuleCategorizer.categorize(rawDescription: merchant))
        return ParseResult(kind: .receipt, transactions: [txn],
                           warnings: date == nil ? ["No date found; used today"] : [])
    }
}

// MARK: - Router

public enum DocumentRouter {
    public enum Input {
        case csv(String)
        case text(String)   // PDF text or OCR text
    }

    /// Picks the right parser for the content.
    public static func parse(_ input: Input, now: Date = Date()) -> ParseResult {
        switch input {
        case .csv(let text):
            let rows = CSV.parse(text)
            if AmazonOrderParser.canParse(rows) { return AmazonOrderParser.parse(rows) }
            if CIBCCSVParser.canParse(rows) { return CIBCCSVParser.parse(rows) }
            if GenericCSVParser.canParse(rows) { return GenericCSVParser.parse(rows) }
            return ParseResult(kind: .genericCSV, transactions: [], warnings: ["Unrecognised CSV layout"])

        case .text(let text):
            var candidates: [ParseResult] = []
            if CIBCCreditCardStatementParser.looksLike(text) {
                candidates.append(CIBCCreditCardStatementParser.parse(text, now: now))
            }
            if CIBCBankStatementParser.looksLike(text) {
                candidates.append(CIBCBankStatementParser.parse(text, now: now))
            }
            if let best = candidates.max(by: { $0.transactions.count < $1.transactions.count }), !best.isEmpty {
                return best
            }
            return ReceiptHeuristicParser.parse(text, now: now)
        }
    }

    /// Whether the text looks like a multi-transaction statement (as opposed
    /// to a single receipt/bill).
    public static func looksLikeStatement(_ text: String) -> Bool {
        CIBCCreditCardStatementParser.looksLike(text) || CIBCBankStatementParser.looksLike(text)
    }
}
