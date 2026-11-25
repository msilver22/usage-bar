import Foundation

public enum AntigravityUsage {
    public static func fetch() async throws -> [UsageWindow] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        guard let executable = paths.map({ "\($0)/agy" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("Install the Antigravity CLI (agy), then run agy to sign in.")
        }
        let session = AntigravitySession(executable: executable, searchPath: paths.joined(separator: ":"))
        return try await withTaskCancellationHandler {
            try await Task.detached { try session.fetch() }.value
        } onCancel: {
            session.stop(cancelled: true)
        }
    }
}

// The lock protects subprocess startup, timeout, and cancellation across queues.
final class AntigravitySession: @unchecked Sendable {
    private let executable: String
    private let searchPath: String
    private let timeoutSeconds: TimeInterval
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    init(executable: String, searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "", timeoutSeconds: TimeInterval = 30) {
        self.executable = executable
        self.searchPath = searchPath
        self.timeoutSeconds = timeoutSeconds
    }

    func stop(cancelled: Bool = false, timedOut: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { self.cancelled = true }
        if timedOut { self.timedOut = true }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func fetch() throws -> [UsageWindow] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Block browser sign-in popups if the agy session has expired.
        let openShim = tempDir.appendingPathComponent("open")
        try "#!/bin/sh\nexit 1\n".write(to: openShim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: openShim.path)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = tempDir
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(tempDir.path):\(searchPath)"
        environment["BROWSER"] = "/usr/bin/false"
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw UsageError.message("Could not start the Antigravity CLI.") }
        lock.unlock()

        let timeout = DispatchWorkItem { self.stop(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer {
            timeout.cancel()
            stop()
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count < 1_048_576 else {
                stop()
                throw UsageError.message("Antigravity returned an oversized response.")
            }
        }
        process.waitUntilExit()

        lock.lock()
        let wasCancelled = cancelled
        let wasTimedOut = timedOut
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasTimedOut { throw UsageError.message("Antigravity took too long to respond. Run agy to check your login and try again.") }
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw UsageError.message("Antigravity could not read usage limits. Run agy in a terminal to check your login, then retry.")
        }
        return try UsageParser.antigravity(data)
    }
}
