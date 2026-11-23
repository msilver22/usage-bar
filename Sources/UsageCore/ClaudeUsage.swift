import Foundation

public enum ClaudeUsage {
    public static func fetch(account: ClaudeAccount) async throws -> [UsageWindow] {
        let service = account.keychainService
        let token = try await Task.detached { try accessToken(service: service) }.value
        try Task.checkCancellation()
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
        case 200: return try UsageParser.claude(data)
        case 401, 403: throw UsageError.message("Claude sign-in expired or access was denied. Run claude and /login, then retry.")
        case 429: throw UsageError.message("Claude is limiting usage checks. Wait a few minutes, then refresh.")
        default: throw UsageError.message("Claude usage is unavailable (HTTP \(http.statusCode)). Try again later.")
        }
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth?
    }

    private static func accessToken(service: String) throws -> String {
        let data = try keychainItem(service: service)
        guard let oauth = try JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty else {
            throw UsageError.message("Sign in to your Claude subscription using claude and /login.")
        }
        if let expiry = oauth.expiresAt, expiry / 1000 <= Date().timeIntervalSince1970 {
            throw UsageError.message("Claude sign-in expired. Open claude to refresh it, then retry.")
        }
        return oauth.accessToken
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

// Never forward a subscription token to a redirected host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
