import SwiftUI
import BillCore

/// Month grid where each day is shaded by how much was spent.
struct SpendingCalendar: View {
    let facts: [TxnFact]
    let month: Date
    var compact = false
    @Binding var selectedDay: Int?

    private var cal: Calendar {
        var c = Calendar.current
        c.timeZone = .current
        return c
    }

    var body: some View {
        let totals = SpendingAnalytics.dailyTotals(facts, month: month)
        let maxDay = totals.values.max() ?? 0
        let start = DateParsing.startOfMonth(month)
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let leading = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let today = cal.isDate(start, equalTo: Date(), toGranularity: .month) ? cal.component(.day, from: Date()) : nil
        let symbols = reorderedWeekdaySymbols()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        VStack(spacing: 4) {
        HStack(spacing: 4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                Text(sym).font(.caption2.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(0..<leading).map { -1 - $0 }, id: \.self) { _ in
                Color.clear.frame(height: compact ? 34 : 46)
            }
            ForEach(1...days, id: \.self) { day in
                let amount = totals[day] ?? 0
                let intensity = maxDay > 0 ? amount / maxDay : 0
                let isFuture = today.map { day > $0 } ?? (start > Date())
                Button {
                    selectedDay = selectedDay == day ? nil : day
                } label: {
                    VStack(spacing: 1) {
                        Text("\(day)")
                            .font(.caption.weight(day == today ? .heavy : .medium))
                            .foregroundStyle(intensity > 0.55 ? Color.white : Color.primary)
                        if !compact {
                            Text(amount > 0 ? compactMoney(amount) : " ")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(intensity > 0.55 ? Color.white.opacity(0.9) : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 34 : 46)
                    .background(cellColor(intensity: intensity, hasSpend: amount > 0, future: isFuture),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if selectedDay == day {
                            RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                        } else if day == today {
                            RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.4), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        }
    }

    private func cellColor(intensity: Double, hasSpend: Bool, future: Bool) -> Color {
        if future { return Color.gray.opacity(0.05) }
        if !hasSpend { return Color.green.opacity(0.12) }        // a no-spend day
        return Color.orange.opacity(0.18 + 0.82 * min(1, intensity))
    }

    private func reorderedWeekdaySymbols() -> [String] {
        let s = cal.veryShortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }
}

/// Full-screen calendar with month navigation, stats and the selected day's purchases.
struct SpendingCalendarScreen: View {
    let facts: [TxnFact]
    @State var month: Date
    @State private var selectedDay: Int?

    var body: some View {
        let monthFacts = SpendingAnalytics.inMonth(facts, month)
        let totals = SpendingAnalytics.dailyTotals(facts, month: month)
        let cal = Calendar.current
        let start = DateParsing.startOfMonth(month)
        let daysSoFar: Int = cal.isDate(start, equalTo: Date(), toGranularity: .month)
            ? cal.component(.day, from: Date())
            : (cal.range(of: .day, in: .month, for: start)?.count ?? 30)
        let noSpend = max(0, daysSoFar - totals.keys.filter { $0 <= daysSoFar }.count)
        let biggest = totals.max { $0.value < $1.value }
        let avg = daysSoFar > 0 ? SpendingAnalytics.totalSpend(monthFacts) / Double(daysSoFar) : 0

        List {
            Section {
                HStack {
                    Button { month = DateParsing.addMonths(-1, to: month); selectedDay = nil } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.monthYear).font(.headline)
                    Spacer()
                    Button { month = DateParsing.addMonths(1, to: month); selectedDay = nil } label: { Image(systemName: "chevron.right") }
                        .disabled(month >= DateParsing.startOfMonth(Date()))
                }
                .buttonStyle(.borderless)
                SpendingCalendar(facts: facts, month: month, selectedDay: $selectedDay)
                    .padding(.vertical, 4)
                HStack {
                    stat("Daily average", money(avg))
                    stat("No-spend days", "\(noSpend)")
                    if let biggest { stat("Biggest day", "\(start.formatted(.dateTime.month(.abbreviated))) \(biggest.key)") }
                }
            } footer: {
                Text("Darker = more spent. Green = a no-spend day. Tap a day to see its purchases.")
            }

            if let day = selectedDay {
                let dayFacts = monthFacts.filter { cal.component(.day, from: $0.date) == day }.sorted { $0.amount > $1.amount }
                Section("\(start.formatted(.dateTime.month(.wide))) \(day) · \(money(SpendingAnalytics.totalSpend(dayFacts)))") {
                    if dayFacts.isEmpty {
                        Text("No transactions — a no-spend day 🎉").foregroundStyle(.secondary)
                    }
                    ForEach(dayFacts) { f in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.merchant)
                                Text([f.categoryName, f.account].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((f.isCredit ? "+" : "") + money(f.amount))
                                .foregroundStyle(f.isCredit ? Color.green : Color.primary)
                        }
                    }
                }
            }

            Section("Biggest days this month") {
                ForEach(Array(totals.sorted { $0.value > $1.value }.prefix(5)), id: \.key) { pair in
                    let date = cal.date(byAdding: .day, value: pair.key - 1, to: start) ?? start
                    Button { selectedDay = pair.key } label: {
                        HStack {
                            Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(money(pair.value)).bold().foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Spending calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
