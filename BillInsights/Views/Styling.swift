import SwiftUI
import BillCore

extension SpendCategory {
    var color: Color {
        switch self {
        case .groceries: return .green
        case .dining: return .orange
        case .transportation: return .blue
        case .fuel: return .indigo
        case .shopping: return .pink
        case .subscriptions: return .purple
        case .utilities: return .yellow
        case .phoneInternet: return .cyan
        case .housing: return .brown
        case .insurance: return .teal
        case .health: return .red
        case .personalCare: return .mint
        case .entertainment: return Color(red: 0.95, green: 0.45, blue: 0.6)
        case .travel: return Color(red: 0.2, green: 0.6, blue: 0.9)
        case .education: return Color(red: 0.5, green: 0.4, blue: 0.9)
        case .giftsDonations: return Color(red: 0.9, green: 0.3, blue: 0.4)
        case .fees: return .gray
        case .income: return .green
        case .transfer: return .secondary
        case .other: return Color(white: 0.6)
        }
    }

    var symbol: String {
        switch self {
        case .groceries: return "cart.fill"
        case .dining: return "fork.knife"
        case .transportation: return "tram.fill"
        case .fuel: return "fuelpump.fill"
        case .shopping: return "bag.fill"
        case .subscriptions: return "repeat.circle.fill"
        case .utilities: return "bolt.fill"
        case .phoneInternet: return "wifi"
        case .housing: return "house.fill"
        case .insurance: return "shield.fill"
        case .health: return "cross.case.fill"
        case .personalCare: return "figure.run"
        case .entertainment: return "ticket.fill"
        case .travel: return "airplane"
        case .education: return "graduationcap.fill"
        case .giftsDonations: return "gift.fill"
        case .fees: return "building.columns.fill"
        case .income: return "arrow.down.circle.fill"
        case .transfer: return "arrow.left.arrow.right"
        case .other: return "questionmark.circle.fill"
        }
    }
}

struct CategoryIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34

    init(category: SpendCategory, size: CGFloat = 34) {
        symbol = category.symbol
        color = category.color
        self.size = size
    }

    init(info: CategoryInfo, size: CGFloat = 34) {
        symbol = info.symbol
        color = info.color
        self.size = size
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.3))
    }
}

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

func money(_ v: Double) -> String { SpendingAnalytics.money(v) }

extension Date {
    var shortDay: String { formatted(.dateTime.month(.abbreviated).day()) }
    var monthYear: String { formatted(.dateTime.month(.wide).year()) }
}
