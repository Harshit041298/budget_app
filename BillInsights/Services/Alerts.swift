import Foundation
import SwiftData
import UserNotifications
import BillCore

/// Local notifications only — scheduled and delivered on the iPhone.
@MainActor
enum Alerts {
    static var budgetAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: "budgetAlertsEnabled") as? Bool ?? true
    }
    static var billRemindersEnabled: Bool {
        UserDefaults.standard.bool(forKey: "billRemindersEnabled")
    }

    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Notifies once per month when a category budget passes 80% and 100%.
    static func checkBudgets(context: ModelContext, now: Date = Date()) async {
        guard budgetAlertsEnabled else { return }
        let budgets = (try? context.fetch(FetchDescriptor<CategoryBudget>())) ?? []
        guard !budgets.isEmpty else { return }
        let facts = AppData.facts(context: context)
        let catalog = CategoryCatalog.load(context)
        let monthKey = DateParsing.isoMonth.string(from: now)
        let defaults = UserDefaults.standard
        for b in budgets where b.monthlyLimit > 0 {
            let spent = SpendingAnalytics.spend(forKey: b.categoryRaw, facts, month: now)
            let name = catalog.info(key: b.categoryRaw).name
            let ratio = spent / b.monthlyLimit
            let level = ratio >= 1 ? 100 : (ratio >= 0.8 ? 80 : 0)
            guard level > 0 else { continue }
            let key = "budgetAlert-\(b.categoryRaw)-\(monthKey)-\(level)"
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            let content = UNMutableNotificationContent()
            content.title = level == 100 ? "\(name) budget exceeded" : "\(name) budget at \(Int(ratio * 100))%"
            content.body = "\(SpendingAnalytics.money(spent)) of \(SpendingAnalytics.money(b.monthlyLimit)) spent this month."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    /// Schedules a reminder 2 days before each detected recurring bill.
    static func rescheduleBillReminders(context: ModelContext, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("bill-") })
        guard billRemindersEnabled else { return }

        let facts = AppData.facts(context: context)
        var cal = Calendar.current
        cal.timeZone = .current
        for r in SpendingAnalytics.recurring(facts, now: now) {
            guard r.nextExpected > now, r.nextExpected < now.addingTimeInterval(45 * 86_400),
                  let remindDay = cal.date(byAdding: .day, value: -2, to: r.nextExpected) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: remindDay)
            comps.hour = 9
            guard let fire = cal.date(from: comps), fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(r.merchant) coming up"
            content.body = "About \(SpendingAnalytics.money(r.typicalAmount)) expected around \(r.nextExpected.formatted(.dateTime.month(.abbreviated).day()))."
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: "bill-\(MerchantNormalizer.key(for: r.merchant))", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}

/// Shows alerts as banners even while the app is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
