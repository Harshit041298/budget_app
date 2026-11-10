import SwiftUI
import SwiftData
import LocalAuthentication
import UserNotifications

@main
struct BillInsightsApp: App {
    @State private var importer = ImportService()

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(importer)
        }
        .modelContainer(AppData.container)
    }
}

struct RootView: View {
    @Environment(ImportService.self) private var importer
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @State private var unlocked = false
    @State private var tab = 0

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                Tab("Insights", systemImage: "chart.pie.fill", value: 0) { DashboardView() }
                Tab("Transactions", systemImage: "list.bullet.rectangle", value: 1) { TransactionsView() }
                Tab("Import", systemImage: "square.and.arrow.down.fill", value: 2) { ImportView() }
                Tab("Ask", systemImage: "sparkles", value: 3) { AskView() }
                Tab("Settings", systemImage: "gearshape.fill", value: 4) { SettingsView() }
            }
            if lockEnabled && !unlocked {
                LockScreen(unlock: authenticate)
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { unlocked = false }
            if phase == .active && lockEnabled && !unlocked { authenticate() }
            if phase == .active {
                Task {
                    await Alerts.rescheduleBillReminders(context: context)
                    await Alerts.checkBudgets(context: context)
                }
            }
        }
        .onOpenURL { url in
            // "Open in Bill Insights" / Share from Files, Mail or the CIBC app.
            tab = 2
            Task { await importer.importFiles([url], context: context) }
        }
        .alert("Import problem", isPresented: Binding(
            get: { importer.errorMessage != nil },
            set: { if !$0 { importer.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.errorMessage ?? "")
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unlocked = true
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your financial data") { ok, _ in
            Task { @MainActor in withAnimation { unlocked = ok } }
        }
    }
}

private struct LockScreen: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Bill Insights is locked").font(.title2.bold())
            Button("Unlock", action: unlock)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
