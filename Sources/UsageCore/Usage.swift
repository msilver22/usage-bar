import Foundation

public struct UsageWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(id: String, usedPercent: Double?, resetsAt: Date?) throws {
        guard usedPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true else {
            throw UsageError.message("The service returned an invalid usage percentage.")
        }
        self.id = id
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public enum UsageError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

public enum UsageParser {
    private struct CodexLimits: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let windowDurationMins: Int?
            let resetsAt: Double?
        }
        struct Bucket: Decodable {
            let primary: Window?
            let secondary: Window?
        }
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }

    public static func codex(_ data: Data) throws -> [UsageWindow] {
        let response = try JSONDecoder().decode(CodexLimits.self, from: data)
        let bucket = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        guard let bucket else { throw UsageError.message("Codex returned no subscription limits. Run codex login with your ChatGPT account.") }
        let windows = try [bucket.primary, bucket.secondary].compactMap { window -> UsageWindow? in
            guard let window else { return nil }
            let label: String
            switch window.windowDurationMins {
            case 300: label = "5 hours"
            case 10080: label = "Week"
            case .some(let minutes): label = "\(minutes) minutes"
            case nil: label = "Usage window"
            }
            return try UsageWindow(id: label, usedPercent: window.usedPercent,
                                   resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
        guard !windows.isEmpty else { throw UsageError.message("This Codex account has no usage windows available.") }
        return windows
    }

    private struct ClaudeLimits: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?
        }
        let five_hour: Window?
        let seven_day: Window?
    }

    public static func claude(_ data: Data) throws -> [UsageWindow] {
        let response = try JSONDecoder().decode(ClaudeLimits.self, from: data)
        guard response.five_hour != nil || response.seven_day != nil else {
            throw UsageError.message("Claude returned no supported subscription usage windows.")
        }
        return try [("5 hours", response.five_hour), ("Week", response.seven_day)].map { label, window in
            let reset: Date?
            if let value = window?.resets_at {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
                guard reset != nil else { throw UsageError.message("Claude returned an invalid reset time.") }
            } else { reset = nil }
            return try UsageWindow(id: label, usedPercent: window?.utilization, resetsAt: reset)
        }
    }
}
