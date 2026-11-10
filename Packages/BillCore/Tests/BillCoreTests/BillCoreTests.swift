import XCTest
@testable import BillCore

final class ParsingTests: XCTestCase {
    func testAmounts() {
        XCTAssertEqual(AmountParsing.parse("1,234.56")?.value, Decimal(string: "1234.56"))
        XCTAssertEqual(AmountParsing.parse("$45.00")?.negative, false)
        XCTAssertEqual(AmountParsing.parse("-45.00")?.negative, true)
        XCTAssertEqual(AmountParsing.parse("45.00-")?.negative, true)
        XCTAssertEqual(AmountParsing.parse("(45.00)")?.negative, true)
        XCTAssertEqual(AmountParsing.parse("45.00 CR")?.negative, true)
        XCTAssertNil(AmountParsing.parse("abc"))
    }

    func testCSVQuotes() {
        let rows = CSV.parse("a,\"b, c\",\"d \"\"x\"\"\"\r\n1,2,3\n")
        XCTAssertEqual(rows, [["a", "b, c", "d \"x\""], ["1", "2", "3"]])
    }

    func testCIBCCSV() {
        let csv = """
        2026-10-04,TIM HORTONS #2345 TORONTO ON,4.50,,4500********1234
        2026-10-05,PAYMENT THANK YOU/PAIEMENT MERCI,,500.00,4500********1234
        2026-10-06,AMAZON.CA*AB12CD AMAZON.CA ON,84.17,,4500********1234
        """
        let r = DocumentRouter.parse(.csv(csv))
        XCTAssertEqual(r.kind, .cibcCSV)
        XCTAssertEqual(r.transactions.count, 3)
        XCTAssertFalse(r.transactions[0].isCredit)
        XCTAssertTrue(r.transactions[1].isCredit)
        XCTAssertEqual(r.transactions[0].account, "Card ••1234")
    }

    func testAmazonOrders() {
        let csv = """
        "Website","Order ID","Order Date","Currency","Total Owed","Quantity","Order Status","Product Name"
        "Amazon.ca","701-1","2026-10-01T18:22:31Z","CAD","30.00","1","Closed","USB-C Cable"
        "Amazon.ca","701-1","2026-10-01T18:22:31Z","CAD","54.17","2","Closed","Coffee Beans 1kg"
        "Amazon.ca","701-2","2026-10-03T10:00:00Z","CAD","12.00","1","Cancelled","Thing"
        """
        let r = DocumentRouter.parse(.csv(csv))
        XCTAssertEqual(r.kind, .amazonOrderHistory)
        XCTAssertEqual(r.transactions.count, 1)
        XCTAssertEqual(r.transactions[0].amount, Decimal(string: "84.17"))
        XCTAssertEqual(r.transactions[0].items, ["USB-C Cable", "2× Coffee Beans 1kg"])
    }

    func testCreditCardStatement() {
        let text = """
        CIBC Dividend Visa Infinite Card
        Statement period Sep 15 to Oct 14, 2026
        Your payments
        Oct 05 Oct 05 PAYMENT THANK YOU/PAIEMENT MERCI 500.00
        Your new charges and credits
        Sep 28 Sep 30 AMAZON.CA*AB12CD AMAZON.CA ON Retail and Grocery 84.17
        Oct 02 Oct 03 THE KEG STEAKHOUSE TORONTO ON Restaurants 112.40
        Oct 07 Oct 08 BEST BUY #123 TORONTO ON Home and Office Improvement 25.00-
        """
        let r = DocumentRouter.parse(.text(text))
        XCTAssertEqual(r.kind, .cibcCreditCardStatement)
        XCTAssertEqual(r.transactions.count, 4)
        XCTAssertTrue(r.transactions[0].isCredit)
        XCTAssertEqual(r.transactions[2].categoryHint, .dining)
        XCTAssertTrue(r.transactions[3].isCredit)
        let d = DateParsing.components(r.transactions[1].date)
        XCTAssertEqual(d.year, 2026); XCTAssertEqual(d.month, 9); XCTAssertEqual(d.day, 28)
    }

    func testYearRollover() {
        let resolver = StatementYearResolver(closingDate: DateParsing.make(year: 2027, month: 1, day: 14)!)
        XCTAssertEqual(DateParsing.components(resolver.date(month: 12, day: 20)!).year, 2026)
        XCTAssertEqual(DateParsing.components(resolver.date(month: 1, day: 3)!).year, 2027)
    }

    func testBankStatementUsesBalanceToFindDirection() {
        let text = """
        CIBC Smart Account statement For Oct 1 to Oct 31, 2026
        Date Description Withdrawals ($) Deposits ($) Balance ($)
        Oct 1 Opening balance 2,500.00
        Oct 3 POINT OF SALE PURCHASE
        TIM HORTONS #2345 4.50
        INTERAC E-TRANSFER 1234 100.00 2,595.50
        Oct 15 PAYROLL DEPOSIT ACME CORP 2,000.00 4,595.50
        Oct 16 PAYMENT CIBC VISA 500.00 4,095.50
        """
        let r = DocumentRouter.parse(.text(text))
        XCTAssertEqual(r.kind, .cibcBankStatement)
        XCTAssertEqual(r.transactions.count, 4)
        XCTAssertFalse(r.transactions[0].isCredit)      // Tim Hortons
        XCTAssertTrue(r.transactions[0].rawDescription.contains("TIM HORTONS"))
        XCTAssertTrue(r.transactions[1].isCredit)       // e-transfer in (balance went up)
        XCTAssertTrue(r.transactions[2].isCredit)       // payroll
        XCTAssertFalse(r.transactions[3].isCredit)      // visa payment
    }

    func testReceipt() {
        let text = """
        FARM BOY #12
        123 Main St, Ottawa
        2026-10-20 14:32
        BANANAS 1.99
        MILK 2L 5.49
        SUBTOTAL 7.48
        HST 0.00
        TOTAL 7.48
        """
        let r = DocumentRouter.parse(.text(text))
        XCTAssertEqual(r.transactions.first?.amount, Decimal(string: "7.48"))
        XCTAssertEqual(r.transactions.first?.categoryHint, .groceries)
    }
}

final class MerchantTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(MerchantNormalizer.normalize("POINT OF SALE PURCHASE TIM HORTONS #2345 TORONTO ON"), "Tim Hortons")
        XCTAssertEqual(MerchantNormalizer.normalize("AMZN Mktp CA*AB12CD"), "Amazon")
        XCTAssertEqual(MerchantNormalizer.normalize("JOE'S PIZZERIA 4421 OTTAWA ON"), "Joe's Pizzeria")
    }

    func testShortKeywordsNeedBoundaries() {
        XCTAssertNotEqual(RuleCategorizer.categorize(rawDescription: "ESPRESSO BAR CAFE"), .fuel)
        XCTAssertEqual(RuleCategorizer.categorize(rawDescription: "ESSO 1234"), .fuel)
    }
}

final class AnalyticsTests: XCTestCase {
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DateParsing.make(year: y, month: m, day: d)! }

    func testRecurringMonthly() {
        let facts = (5...10).map { m in
            TxnFact(date: day(2026, m, 3), merchant: "Netflix", amount: 16.49, isCredit: false, category: .subscriptions)
        }
        let r = SpendingAnalytics.recurring(facts, now: day(2026, 10, 20))
        XCTAssertEqual(r.first?.cadence, .monthly)
        XCTAssertEqual(r.first?.merchant, "Netflix")
    }

    func testRefundsReduceSpendAndTransfersIgnored() {
        let facts = [
            TxnFact(date: day(2026, 10, 1), merchant: "Best Buy", amount: 100, isCredit: false, category: .shopping),
            TxnFact(date: day(2026, 10, 2), merchant: "Best Buy", amount: 30, isCredit: true, category: .shopping),
            TxnFact(date: day(2026, 10, 3), merchant: "Card Payment", amount: 500, isCredit: true, category: .transfer)
        ]
        XCTAssertEqual(SpendingAnalytics.totalSpend(facts), 70, accuracy: 0.001)
    }

    func testOrderMatching() {
        let o = UUID(), c = UUID()
        let m = OrderMatcher.match(orders: [.init(id: o, date: day(2026, 10, 1), amount: 84.17)],
                                   charges: [.init(id: c, date: day(2026, 10, 3), amount: 84.17),
                                             .init(id: UUID(), date: day(2026, 10, 3), amount: 84.00)])
        XCTAssertEqual(m[o], c)
    }
}

final class LiveMatcherTests: XCTestCase {
    func day(_ m: Int, _ d: Int) -> Date { DateParsing.make(year: 2026, month: m, day: d)! }

    func testExactAndTipMatches() {
        let l1 = UUID(), l2 = UUID(), s1 = UUID(), s2 = UUID(), s3 = UUID()
        let m = LiveMatcher.match(
            live: [.init(id: l1, date: day(10, 3), amount: 4.50, merchant: "Tim Hortons"),
                   .init(id: l2, date: day(10, 5), amount: 80.00, merchant: "The Keg")],
            statement: [.init(id: s1, date: day(10, 4), amount: 4.50, merchant: "TIM HORTONS #2345 TORONTO ON"),
                        .init(id: s2, date: day(10, 6), amount: 96.00, merchant: "THE KEG STEAKHOUSE TORONTO ON"),
                        .init(id: s3, date: day(10, 6), amount: 96.00, merchant: "SHELL C123")])
        XCTAssertEqual(m[l1], s1)
        XCTAssertEqual(m[l2], s2)
    }

    func testNoMatchWhenFarApart() {
        let l = UUID()
        let m = LiveMatcher.match(live: [.init(id: l, date: day(10, 1), amount: 10, merchant: "A")],
                                  statement: [.init(id: UUID(), date: day(10, 20), amount: 10, merchant: "A")])
        XCTAssertNil(m[l])
    }

    func testParseAmount() {
        XCTAssertEqual(LiveMatcher.parseAmount("CA$4.50"), 4.50)
        XCTAssertEqual(LiveMatcher.parseAmount("$1,234.00"), 1234.00)
        XCTAssertEqual(LiveMatcher.parseAmount("4,50 $"), 4.50)
        XCTAssertNil(LiveMatcher.parseAmount("abc"))
    }

    func testForecastOnlyForCurrentMonth() {
        let facts = [TxnFact(date: day(10, 2), merchant: "X", amount: 100, isCredit: false, category: .dining)]
        XCTAssertNil(SpendingAnalytics.forecast(facts, month: day(9, 1), now: day(10, 10)))
        let f = SpendingAnalytics.forecast(facts, month: day(10, 1), now: day(10, 10))
        XCTAssertNotNil(f)
        XCTAssertGreaterThan(f!, 100)
    }
}

final class AccountAndCustomTests: XCTestCase {
    func day(_ m: Int, _ d: Int) -> Date { DateParsing.make(year: 2026, month: m, day: d)! }

    func testCustomCategoriesAndAccounts() {
        let facts = [
            TxnFact(date: day(10, 1), merchant: "A", amount: 50, isCredit: false, category: .shopping,
                    customKey: "custom:x", customName: "Hobbies", account: "Visa ••1234", accountKind: "credit"),
            TxnFact(date: day(10, 2), merchant: "B", amount: 30, isCredit: false, category: .shopping,
                    account: "CIBC Chequing", accountKind: "debit"),
            TxnFact(date: day(10, 3), merchant: "Card Payment", amount: 500, isCredit: true, category: .transfer,
                    account: "Visa ••1234", accountKind: "credit")
        ]
        let cats = SpendingAnalytics.byCategoryKey(facts)
        XCTAssertEqual(cats.first { $0.key == "custom:x" }?.name, "Hobbies")
        XCTAssertEqual(cats.first { $0.key == "shopping" }?.total, 30)
        let accounts = SpendingAnalytics.byAccount(facts)
        XCTAssertEqual(accounts.first { $0.account == "Visa ••1234" }?.spend, 50)
        XCTAssertEqual(accounts.first { $0.account == "Visa ••1234" }?.credits, 500)
    }

    func testPriceIncrease() {
        var facts = (5...9).map { m in
            TxnFact(date: day(m, 3), merchant: "Spotify", amount: 11.99, isCredit: false, category: .subscriptions)
        }
        facts.append(TxnFact(date: day(10, 3), merchant: "Spotify", amount: 12.99, isCredit: false, category: .subscriptions))
        let changes = SpendingAnalytics.priceChanges(facts, now: day(10, 10))
        XCTAssertEqual(changes.first?.newAmount, 12.99)
        XCTAssertEqual(changes.first?.oldAmount, 11.99)
    }
}

final class ChartDataTests: XCTestCase {
    func day(_ m: Int, _ d: Int) -> Date { DateParsing.make(year: 2026, month: m, day: d)! }

    func testCumulativeDaily() {
        let facts = [
            TxnFact(date: day(10, 2), merchant: "A", amount: 10, isCredit: false, category: .dining),
            TxnFact(date: day(10, 5), merchant: "B", amount: 20, isCredit: false, category: .dining)
        ]
        let pts = SpendingAnalytics.cumulativeDaily(facts, month: day(10, 1), upTo: day(10, 6))
        XCTAssertEqual(pts.count, 6)
        XCTAssertEqual(pts[1].total, 10)
        XCTAssertEqual(pts[5].total, 30)
        XCTAssertEqual(SpendingAnalytics.cumulativeDaily(facts, month: day(10, 1)).count, 31)
    }

    func testWeekdayAndTrend() {
        let facts = (1...28).map { d in
            TxnFact(date: day(10, d), merchant: "A", amount: Double(d), isCredit: false, category: d % 2 == 0 ? .dining : .groceries)
        }
        let w = SpendingAnalytics.byWeekday(facts)
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(w.reduce(0) { $0 + $1.total }, Double((1...28).reduce(0, +)), accuracy: 0.001)
        let trend = SpendingAnalytics.categoryTrend(facts, months: 3, endingAt: day(10, 1), top: 1)
        XCTAssertEqual(Set(trend.map(\.key)), ["dining", "_rest"])
        XCTAssertEqual(SpendingAnalytics.monthsWithData(facts), 1)
    }
}

final class CalendarTests: XCTestCase {
    func testDailyTotals() {
        let d = { (day: Int) in DateParsing.make(year: 2026, month: 10, day: day)! }
        let facts = [
            TxnFact(date: d(3), merchant: "A", amount: 10, isCredit: false, category: .dining),
            TxnFact(date: d(3), merchant: "B", amount: 5, isCredit: false, category: .dining),
            TxnFact(date: d(4), merchant: "Pay", amount: 500, isCredit: true, category: .transfer)
        ]
        let t = SpendingAnalytics.dailyTotals(facts, month: d(1))
        XCTAssertEqual(t[3], 15)
        XCTAssertNil(t[4])
    }
}

final class ParseAmountTests: XCTestCase {
    func testWholeTransactionText() {
        XCTAssertEqual(LiveMatcher.parseAmount("7-Eleven #123, $4.50, CIBC Visa"), 4.50)
        XCTAssertEqual(LiveMatcher.parseAmount("Tim Hortons 12.25"), 12.25)
        XCTAssertEqual(LiveMatcher.parseAmount("4.5"), 4.5)
        XCTAssertEqual(LiveMatcher.parseAmount("CAD 20"), 20)
        XCTAssertNil(LiveMatcher.parseAmount("Store 7"))
    }
}

final class SavingsPlannerTests: XCTestCase {
    func day(_ m: Int, _ d: Int) -> Date { DateParsing.make(year: 2026, month: m, day: d)! }

    func testPlanCoversGapFromFlexibleCategoriesOnly() {
        var facts: [TxnFact] = []
        for m in 7...9 {
            facts.append(TxnFact(date: day(m, 1), merchant: "Payroll", amount: 4000, isCredit: true, category: .income))
            facts.append(TxnFact(date: day(m, 2), merchant: "Landlord", amount: 1800, isCredit: false, category: .housing))
            facts.append(TxnFact(date: day(m, 5), merchant: "Keg", amount: 600, isCredit: false, category: .dining))
            facts.append(TxnFact(date: day(m, 9), merchant: "Amazon", amount: 800, isCredit: false, category: .shopping))
        }
        let b = SavingsPlanner.baseline(facts, months: 3, now: day(10, 15))
        XCTAssertEqual(b.months, 3)
        XCTAssertEqual(b.avgIncome, 4000, accuracy: 0.01)
        XCTAssertEqual(b.avgSaved, 800, accuracy: 0.01)
        let plan = SavingsPlanner.plan(b, target: 1200)
        XCTAssertEqual(plan.gap, 400, accuracy: 0.01)
        XCTAssertTrue(plan.achievable)
        XCTAssertGreaterThanOrEqual(plan.plannedSaving, 400)
        XCTAssertFalse(plan.cuts.contains { $0.base == .housing })
    }

    func testAlreadyOnTrack() {
        let b = SavingsBaseline(months: 3, avgIncome: 5000, avgSpend: 3000, categories: [])
        XCTAssertEqual(SavingsPlanner.plan(b, target: 1500).gap, 0)
    }
}

final class AskContextTests: XCTestCase {
    func day(_ m: Int, _ d: Int) -> Date { DateParsing.make(year: 2026, month: m, day: d)! }

    func testShoppingQuestionListsMerchants() {
        let facts = [
            TxnFact(date: day(10, 2), merchant: "Amazon", amount: 120, isCredit: false, category: .shopping, items: ["USB cable"]),
            TxnFact(date: day(10, 5), merchant: "Winners", amount: 60, isCredit: false, category: .shopping),
            TxnFact(date: day(10, 6), merchant: "Landlord", amount: 1400, isCredit: false, category: .housing)
        ]
        let ctx = AskContextBuilder.build(question: "Where am I spending most in shopping?", facts: facts, now: day(10, 20))
        XCTAssertTrue(ctx.contains("Amazon"))
        XCTAssertTrue(ctx.contains("Winners"))
        XCTAssertTrue(ctx.contains("USB cable"))
        XCTAssertLessThanOrEqual(ctx.count, 1800)
    }

    func testSavingsQuestionMarksEssentials() {
        var facts: [TxnFact] = []
        for m in 7...9 {
            facts.append(TxnFact(date: day(m, 1), merchant: "Payroll", amount: 4000, isCredit: true, category: .income))
            facts.append(TxnFact(date: day(m, 2), merchant: "Landlord", amount: 1400, isCredit: false, category: .housing))
            facts.append(TxnFact(date: day(m, 3), merchant: "Amazon", amount: 1300, isCredit: false, category: .shopping))
        }
        let ctx = AskContextBuilder.build(question: "How can I save $1,500 a month?", facts: facts, now: day(10, 10))
        XCTAssertTrue(ctx.contains("do NOT suggest cutting"))
        XCTAssertTrue(ctx.contains("Rent & Housing"))
        XCTAssertTrue(ctx.contains("Savings goal $1,500"))
    }

    func testPeriods() {
        XCTAssertEqual(AskContextBuilder.period(for: "last month", now: day(10, 10)).label, SpendingAnalytics.monthLabel(day(9, 1)))
        XCTAssertEqual(AskContextBuilder.period(for: "spending in august", now: day(10, 10)).label, SpendingAnalytics.monthLabel(day(8, 1)))
    }
}

final class AskEngineTests: XCTestCase {
    func day(_ m: Int, _ d: Int) -> Date { DateParsing.make(year: 2026, month: m, day: d)! }

    var facts: [TxnFact] {
        [
            TxnFact(date: day(9, 12), merchant: "Amazon", amount: 42.98, isCredit: false, category: .shopping),
            TxnFact(date: day(10, 2), merchant: "Amazon", amount: 84.17, isCredit: false, category: .shopping),
            TxnFact(date: day(10, 4), merchant: "Instacart", amount: 760.33, isCredit: false, category: .groceries),
            TxnFact(date: day(10, 8), merchant: "Walmart", amount: 127.87, isCredit: false, category: .shopping),
            TxnFact(date: day(10, 1), merchant: "Amazon", amount: 84.17, isCredit: false, category: .shopping,
                    countsAsSpending: false, items: ["USB cable"])
        ]
    }

    func testAmazonLastMonthIsExact() {
        let now = day(11, 10)
        let q = AskEngine.parse("how much I spent on amazon last month", facts: facts, previous: nil, now: now)
        XCTAssertEqual(q.merchants, ["Amazon"])
        XCTAssertEqual(q.intent, .total)
        let a = AskEngine.answer(q, facts: facts, now: now)!
        XCTAssertTrue(a.contains("$84.17"), a)
        XCTAssertTrue(a.contains("aren't counted"), a)
        XCTAssertFalse(a.contains("760"), a)
    }

    func testFollowUpInheritsSubject() {
        let now = day(11, 10)
        let first = AskEngine.parse("how much did I spend at amazon last month", facts: facts, previous: nil, now: now)
        let follow = AskEngine.parse("In sep?", facts: facts, previous: first, now: now)
        XCTAssertEqual(follow.merchants, ["Amazon"])
        XCTAssertEqual(follow.period.label, SpendingAnalytics.monthLabel(day(9, 1)))
        XCTAssertTrue(AskEngine.answer(follow, facts: facts, now: now)!.contains("$42.98"))
    }

    func testShoppingWhereMost() {
        let now = day(10, 20)
        let q = AskEngine.parse("Where am I spending the most in shopping?", facts: facts, previous: nil, now: now)
        XCTAssertEqual(q.intent, .top)
        let a = AskEngine.answer(q, facts: facts, now: now)!
        XCTAssertTrue(a.contains("Walmart"), a)
        XCTAssertFalse(a.contains("Instacart"), a)
    }

    func testAdviceGoesToAI() {
        let q = AskEngine.parse("How can I save $1,500 a month?", facts: facts, previous: nil, now: day(10, 20))
        XCTAssertNil(AskEngine.answer(q, facts: facts, now: day(10, 20)))
    }
}
