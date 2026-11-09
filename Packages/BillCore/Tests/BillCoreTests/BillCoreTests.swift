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
