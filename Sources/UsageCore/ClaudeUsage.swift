import Foundation
import Security

public enum ClaudeUsage {
    public static func fetch() async throws -> [UsageWindow] {
        let token = try await Task.detached { try accessToken() }.value
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

    private static func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw UsageError.message("Allow UsageBar to read the Claude Code keychain entry, or sign in using claude and /login.")
        }
        guard let oauth = try JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty else {
            throw UsageError.message("Sign in to your Claude subscription using claude and /login.")
        }
        if let expiry = oauth.expiresAt, expiry / 1000 <= Date().timeIntervalSince1970 {
            throw UsageError.message("Claude sign-in expired. Open claude to refresh it, then retry.")
        }
        return oauth.accessToken
    }
}

// Never forward a subscription token to a redirected host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
