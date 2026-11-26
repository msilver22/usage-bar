import Foundation

public enum ClaudeUsage {
    public static func fetch(account: ClaudeAccount) async throws -> [UsageWindow] {
        let service = account.keychainService
        let readToken = { try await Task.detached { try accessToken(service: service) }.value }
        var refreshed = false
        var token: String
        switch try await readToken() {
        case .valid(let value):
            token = value
        case .expired:
            refreshed = true
            try await refreshThroughCLI(configDir: account.configDir)
            guard case .valid(let value) = try await readToken() else {
                throw UsageError.message("Claude sign-in expired. Open claude to refresh it, then retry.")
            }
            token = value
        }
        try Task.checkCancellation()
        switch try await requestUsage(token: token) {
        case .windows(let windows):
            return windows
        case .unauthorized where !refreshed:
            try await refreshThroughCLI(configDir: account.configDir)
            try Task.checkCancellation()
            guard case .valid(let freshToken) = try await readToken() else {
                throw UsageError.message("Claude sign-in expired. Open claude to refresh it, then retry.")
            }
            if case .windows(let windows) = try await requestUsage(token: freshToken) {
                return windows
            }
            throw UsageError.message("Claude sign-in expired or access was denied. Run claude and /login, then retry.")
        case .unauthorized:
            throw UsageError.message("Claude sign-in expired or access was denied. Run claude and /login, then retry.")
        }
    }

    private enum TokenLookup: Sendable {
        case valid(String)
        case expired
    }

    private enum UsageResponse {
        case windows([UsageWindow])
        case unauthorized
    }

    private static func requestUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("UsageBar/0.1.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.message("Claude returned an unexpected response.") }
        switch http.statusCode {
        case 200: return .windows(try UsageParser.claude(data))
        case 401: return .unauthorized
        case 403: throw UsageError.message("Claude sign-in expired or access was denied. Run claude and /login, then retry.")
        case 429: throw UsageError.message("Claude is limiting usage checks. Wait a few minutes, then refresh.")
        default: throw UsageError.message("Claude usage is unavailable (HTTP \(http.statusCode)). Try again later.")
        }
    }

    /// Delegates OAuth refresh to Claude Code (`claude doctor`) so Claude remains the sole writer to its
    /// Keychain entry (preserving rotating refresh tokens and Keychain ACLs). Best-effort: failure falls back
    /// to the normal expired-login error.
    private static func refreshThroughCLI(configDir: String?) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        guard let executable = paths.map({ "\($0)/claude" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        let session = ClaudeRefreshSession(executable: executable, configDir: configDir, searchPath: paths.joined(separator: ":"))
        try await withTaskCancellationHandler {
            try await Task.detached { try session.run() }.value
        } onCancel: {
            session.stop()
        }
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth?
    }

    private static func accessToken(service: String) throws -> TokenLookup {
        let data = try keychainItem(service: service)
        guard let oauth = try JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty else {
            throw UsageError.message("Sign in to your Claude subscription using claude and /login.")
        }
        if let expiry = oauth.expiresAt, expiry / 1000 <= Date().timeIntervalSince1970 {
            return .expired
        }
        return .valid(oauth.accessToken)
    }

    // Claude Code writes its credentials with /usr/bin/security, so the item's ACL trusts only that tool.
    // Reading through it avoids a keychain prompt that would otherwise return after every rebuild of this
    // ad-hoc signed app and whenever Claude Code rewrites the item on token refresh.
    private static func keychainItem(service: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw UsageError.message("Could not run /usr/bin/security to read the Claude Code login.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0 where !data.isEmpty:
            // `security -w` ends the secret with a newline.
            return data.last == UInt8(ascii: "\n") ? data.dropLast() : data
        case 44: throw UsageError.message("No Claude Code login found. Sign in using claude and /login.")
        default: throw UsageError.message("Could not read the Claude Code keychain entry. Open claude to check your login, then retry.")
        }
    }
}

final class ClaudeRefreshSession: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private let timeoutSeconds: TimeInterval

    init(executable: String, configDir: String?, searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
         timeoutSeconds: TimeInterval = 15) {
        self.timeoutSeconds = timeoutSeconds
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["doctor"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["DISABLE_AUTOUPDATER"] = "1"
        if let configDir {
            environment["CLAUDE_CONFIG_DIR"] = configDir
        } else {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func stop(cancelled: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { self.cancelled = true }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func run() throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); return }
        lock.unlock()
        let timeout = DispatchWorkItem { self.stop(cancelled: false) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer {
            timeout.cancel()
            stop(cancelled: false)
            process.waitUntilExit()
        }
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
    }
}

// Never forward a subscription token to a redirected host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
