import Foundation
import CryptoKit
import SwiftData
import BillCore

/// Keeps security-sensitive details out of storage and out of anything sent
/// to a cloud model.
@MainActor
enum Privacy {
    /// When off (default), the text extracted from statements is not kept at all.
    static let keepTextKey = "keepStatementText"
    static var keepStatementText: Bool { UserDefaults.standard.bool(forKey: keepTextKey) }

    /// Duplicate-detection fingerprints are stored only as a one-way hash, so
    /// they can't leak description text.
    nonisolated static func hash(_ fingerprint: String) -> String {
        if fingerprint.hasPrefix("h:") { return fingerprint }
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return "h:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What to store for a statement's extracted text.
    static func storedText(_ raw: String) -> String {
        keepStatementText ? String(Redactor.redact(raw).prefix(200_000)) : ""
    }

    /// Statements opened via "Open in Bill Insights" are copied into the app's
    /// Inbox folder by iOS — delete those copies once imported.
    static func deleteInboxCopy(_ url: URL) {
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
    }

    /// One-time clean-up of data saved before the privacy layer existed.
    static func migrateIfNeeded(context: ModelContext) {
        let flag = "privacyMigration-v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        for e in (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? [] {
            e.rawDescription = Redactor.redact(e.rawDescription)
            e.fingerprint = hash(e.fingerprint)
            e.notes = Redactor.redact(e.notes)
        }
        for d in (try? context.fetch(FetchDescriptor<ImportedDocument>())) ?? [] {
            d.extractedText = storedText(d.extractedText)
            d.filename = Redactor.redact(d.filename)
        }
        try? context.save()
        // Remove any leftover statement copies in the Inbox folder.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let inbox = docs.appendingPathComponent("Inbox")
            try? FileManager.default.removeItem(at: inbox)
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}
