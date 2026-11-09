import Foundation

/// Links Amazon orders (from order history) to the matching card charges so a
/// "$84.17 AMAZON.CA" line on your CIBC statement shows what you actually bought.
public enum OrderMatcher {
    public struct Item: Sendable {
        public var id: UUID
        public var date: Date
        public var amount: Double
        public init(id: UUID, date: Date, amount: Double) {
            self.id = id; self.date = date; self.amount = amount
        }
    }

    /// Returns `[orderID: chargeID]`. Charges usually post 0–10 days after the
    /// order (when it ships); amounts must match to the cent.
    public static func match(orders: [Item], charges: [Item]) -> [UUID: UUID] {
        var used = Set<UUID>()
        var result: [UUID: UUID] = [:]
        for order in orders.sorted(by: { $0.date < $1.date }) {
            let best = charges
                .filter { !used.contains($0.id) && abs($0.amount - order.amount) < 0.015 }
                .map { ($0, DateParsing.days(from: order.date, to: $0.date)) }
                .filter { $0.1 >= -2 && $0.1 <= 12 }
                .min { abs($0.1) < abs($1.1) }
            if let charge = best?.0 {
                used.insert(charge.id)
                result[order.id] = charge.id
            }
        }
        return result
    }
}
