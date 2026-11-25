import Foundation
import Combine
import UsageCore

/// One usage card: a Claude login (one per organization/config directory), Codex, or Antigravity.
struct Provider: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case claude(ClaudeAccount)
        case codex
        case antigravity
    }
    let kind: Kind

    var id: String {
        switch kind {
        case .claude(let account): "claude:\(account.id)"
        case .codex: "codex"
        case .antigravity: "antigravity"
        }
    }
    var name: String {
        switch kind {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
    /// Organization name for Claude logins, shown next to the provider name.
    var detail: String? {
        if case .claude(let account) = kind { return account.organization }
        return nil
    }
    var label: String { [name, detail].compactMap { $0 }.joined(separator: " · ") }
    var dashboard: URL {
        switch kind {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .antigravity: URL(string: "https://antigravity.google")!
        }
    }

    func fetch() async throws -> [UsageWindow] {
        switch kind {
        case .claude(let account): try await ClaudeUsage.fetch(account: account)
        case .codex: try await CodexUsage.fetch()
        case .antigravity: try await AntigravityUsage.fetch()
        }
    }

    /// Every Claude login found on this Mac, then Codex and Antigravity. With no Claude login at all,
    /// the default account is still listed so its card can explain how to sign in.
    static func discover() -> [Provider] {
        var accounts = ClaudeAccount.discover()
        if accounts.isEmpty {
            accounts = [ClaudeAccount(keychainService: ClaudeAccount.keychainService(configDir: nil), organization: nil)]
        }
        return accounts.map { Provider(kind: .claude($0)) } + [Provider(kind: .codex), Provider(kind: .antigravity)]
    }
}

struct UsageState {
    var windows: [UsageWindow] = []
    var updatedAt: Date?
    var error: String?
    var loading = false
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var providers = Provider.discover()
    @Published var states: [String: UsageState] = [:]
    @Published var showingSettings = false
    private var discovery: Task<Void, Never>?
    private var tasks: [String: Task<Void, Never>] = [:]

    var isLoading: Bool { states.values.contains { $0.loading } }

    /// Re-discovers logins (so a new `claude /login` in another config directory shows up), then
    /// checks every provider in parallel.
    func refresh() {
        cancel()
        for provider in providers { states[provider.id, default: UsageState()].loading = true }
        discovery = Task {
            let found = await Task.detached { Provider.discover() }.value
            guard !Task.isCancelled else { return }
            providers = found
            states = states.filter { key, _ in found.contains { $0.id == key } }
            for provider in found { start(provider) }
        }
    }

    private func start(_ provider: Provider) {
        states[provider.id, default: UsageState()].loading = true
        states[provider.id]?.error = nil
        tasks[provider.id] = Task {
            do {
                let windows = try await provider.fetch()
                guard !Task.isCancelled else { return }
                states[provider.id] = UsageState(windows: windows, updatedAt: Date())
            } catch {
                guard !Task.isCancelled else { return }
                states[provider.id]?.loading = false
                states[provider.id]?.error = error is DecodingError
                    ? "The service returned an unsupported usage format."
                    : error.localizedDescription
            }
        }
    }

    func cancel() {
        discovery?.cancel()
        discovery = nil
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        for key in states.keys { states[key]?.loading = false }
    }
}
