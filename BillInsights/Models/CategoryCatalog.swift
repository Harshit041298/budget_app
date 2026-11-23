import SwiftUI
import SwiftData
import BillCore

/// A category as shown in the UI: one of the built-in ones or a custom one.
struct CategoryInfo: Identifiable, Hashable {
    let key: String
    let name: String
    let symbol: String
    let color: Color
    let base: SpendCategory
    var id: String { key }
    var isCustom: Bool { key.hasPrefix("custom:") }

    static func builtin(_ c: SpendCategory) -> CategoryInfo {
        CategoryInfo(key: c.rawValue, name: c.displayName, symbol: c.symbol, color: c.color, base: c)
    }

    static let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
    static let symbols: [String] = [
        "tag.fill", "pawprint.fill", "car.fill", "gift.fill", "heart.fill", "gamecontroller.fill", "book.fill",
        "figure.2.and.child.holdinghands", "house.fill", "wrench.and.screwdriver.fill", "tshirt.fill", "cup.and.saucer.fill",
        "music.note", "camera.fill", "graduationcap.fill", "stethoscope", "dumbbell.fill", "airplane",
        "leaf.fill", "banknote.fill", "briefcase.fill", "laptopcomputer", "sparkles", "star.fill"
    ]
}

/// Resolves category keys (built-in raw values or "custom:<uuid>") to display info.
struct CategoryCatalog {
    let customs: [CategoryInfo]
    private let byKey: [String: CategoryInfo]

    init(_ models: [CustomCategory]) {
        customs = models.sorted { $0.name < $1.name }.map {
            CategoryInfo(key: $0.key, name: $0.name, symbol: $0.symbol,
                         color: CategoryInfo.palette[abs($0.colorIndex) % CategoryInfo.palette.count], base: $0.base)
        }
        byKey = Dictionary(uniqueKeysWithValues: customs.map { ($0.key, $0) })
    }

    /// Custom categories first, then built-ins.
    var all: [CategoryInfo] { customs + SpendCategory.allCases.map(CategoryInfo.builtin) }

    func custom(key: String) -> CategoryInfo? { byKey[key] }

    func info(key: String) -> CategoryInfo {
        byKey[key] ?? .builtin(SpendCategory(rawValue: key) ?? .other)
    }

    func info(for entry: LedgerEntry) -> CategoryInfo { info(key: entry.categoryKey) }

    @MainActor
    static func load(_ context: ModelContext) -> CategoryCatalog {
        CategoryCatalog((try? context.fetch(FetchDescriptor<CustomCategory>())) ?? [])
    }
}
