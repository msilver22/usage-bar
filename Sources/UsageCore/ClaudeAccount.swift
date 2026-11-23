import CryptoKit
import Foundation

/// A Claude Code login. Each `CLAUDE_CONFIG_DIR` keeps its own login, so separate config
/// directories are how one person is signed in to several Claude organizations at once.
public struct ClaudeAccount: Sendable, Hashable, Identifiable {
    /// Keychain service holding this login's OAuth credentials.
    public let keychainService: String
    /// Organization name recorded by Claude Code at login, if available.
    public let organization: String?
    public var id: String { keychainService }

    public init(keychainService: String, organization: String?) {
        self.keychainService = keychainService
        self.organization = organization
    }

    /// Claude Code names the item `Claude Code-credentials` for the default config directory and
    /// appends the first 8 hex digits of SHA-256(config dir path) for any other `CLAUDE_CONFIG_DIR`.
    public static func keychainService(configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    /// The default login (`~/.claude`) plus every `~/.claude-*` config directory, keeping only
    /// those that have credentials in the keychain. The default account comes first.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                hasCredentials: (String) -> Bool = keychainItemExists) -> [ClaudeAccount] {
        var accounts = [ClaudeAccount(keychainService: keychainService(configDir: nil),
                                      organization: organization(in: home.appendingPathComponent(".claude.json")))]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names.sorted() where name.hasPrefix(".claude-") {
            let dir = home.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            accounts.append(ClaudeAccount(keychainService: keychainService(configDir: dir.path),
                                          organization: organization(in: dir.appendingPathComponent(".claude.json"))))
        }
        return accounts.filter { hasCredentials($0.keychainService) }
    }

    private static func organization(in file: URL) -> String? {
        struct Config: Decodable {
            struct Account: Decodable { let organizationName: String? }
            let oauthAccount: Account?
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONDecoder().decode(Config.self, from: data))?.oauthAccount?.organizationName
    }

    /// Checks the item's attributes only; reading attributes never prompts and never exposes the secret.
    public static func keychainItemExists(_ service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
