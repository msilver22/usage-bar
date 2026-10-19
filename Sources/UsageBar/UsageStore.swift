import Foundation
import Combine
import UsageCore

enum Service: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    var id: String { rawValue }
    var dashboard: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
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
    @Published var states = Dictionary(uniqueKeysWithValues: Service.allCases.map { ($0, UsageState()) })
    @Published var showingSettings = false
    private var tasks: [Service: Task<Void, Never>] = [:]

    func refresh() {
        cancel()
        for service in Service.allCases {
            states[service]?.loading = true
            states[service]?.error = nil
            tasks[service] = Task {
                do {
                    let windows = try await (service == .claude ? ClaudeUsage.fetch() : CodexUsage.fetch())
                    guard !Task.isCancelled else { return }
                    states[service] = UsageState(windows: windows, updatedAt: Date())
                } catch {
                    guard !Task.isCancelled else { return }
                    states[service]?.loading = false
                    states[service]?.error = error is DecodingError
                        ? "The service returned an unsupported usage format."
                        : error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        for service in Service.allCases { states[service]?.loading = false }
    }
}
