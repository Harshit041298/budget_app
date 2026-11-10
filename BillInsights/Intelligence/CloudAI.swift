import Foundation
import Security

/// Optional cloud model (Claude) for open-ended advice. Off by default.
/// Only a short, app-computed summary is sent — never statements, account
/// numbers or full transaction history. The API key lives in the Keychain.
@MainActor
enum CloudAI {
    enum Model: String, CaseIterable, Identifiable {
        case sonnet = "claude-sonnet-5-5"
        case opus = "claude-opus-5-5"
        var id: String { rawValue }
        var displayName: String { self == .sonnet ? "Claude Sonnet 5.5" : "Claude Opus 5.5" }
        var detail: String { self == .sonnet ? "Recommended · ~$0.007 per question" : "Smartest · ~$0.016 per question" }
        /// USD per million tokens (input, output).
        var price: (input: Double, output: Double) { self == .sonnet ? (2, 10) : (4, 20) }
    }

    enum Failure: LocalizedError {
        case noKey, badKey, rateLimited, overloaded, refused, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .noKey: return "No Claude API key saved. Add one in Settings → Cloud AI."
            case .badKey: return "Claude rejected the API key. Check it in Settings → Cloud AI."
            case .rateLimited: return "Too many requests or no credit left. Check your Anthropic Console billing."
            case .overloaded: return "Claude is busy right now. Try again in a moment."
            case .refused: return "Claude declined to answer that request."
            case .http(let code, let msg): return "Claude error \(code): \(msg)"
            case .empty: return "Claude returned an empty answer."
            }
        }
    }

    static let enabledKey = "cloudAIEnabled"
    static let modelKey = "cloudAIModel"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var model: Model { Model(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .sonnet }
    static var hasKey: Bool { Keychain.read() != nil }
    static var isReady: Bool { isEnabled && hasKey }

    /// One request to the Messages API. `effort`: "low" for chat, "medium" for reports.
    static func complete(system: String, prompt: String, effort: String = "low", maxTokens: Int = 4000) async throws -> String {
        guard let key = Keychain.read() else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallback: if a safety classifier declines, the API
        // retries on a fallback model within the same call.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "system": system,
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Unknown error"
            switch status {
            case 401, 403: throw Failure.badKey
            case 429: throw Failure.rateLimited
            case 500...599: throw Failure.overloaded
            default: throw Failure.http(status, message)
            }
        }
        if let usage = json["usage"] as? [String: Any] {
            let input = (usage["input_tokens"] as? Double) ?? Double(usage["input_tokens"] as? Int ?? 0)
            let output = (usage["output_tokens"] as? Double) ?? Double(usage["output_tokens"] as? Int ?? 0)
            recordCost(input: input, output: output)
        }
        if (json["stop_reason"] as? String) == "refusal" { throw Failure.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }

    // MARK: Cost tracking (estimate, using the selected model's prices)

    private static func costKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return "cloudAICost-" + f.string(from: date)
    }

    private static func recordCost(input: Double, output: Double) {
        let p = model.price
        let cost = input / 1_000_000 * p.input + output / 1_000_000 * p.output
        let key = costKey()
        UserDefaults.standard.set(UserDefaults.standard.double(forKey: key) + cost, forKey: key)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key + "-count") + 1, forKey: key + "-count")
    }

    static var costThisMonth: Double { UserDefaults.standard.double(forKey: costKey()) }
    static var requestsThisMonth: Int { UserDefaults.standard.integer(forKey: costKey() + "-count") }
}

/// Minimal Keychain wrapper for the API key (device-only, not synced to iCloud).
enum Keychain {
    private static let service = "BillInsights.ClaudeAPIKey"

    static func save(_ value: String) -> Bool {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
