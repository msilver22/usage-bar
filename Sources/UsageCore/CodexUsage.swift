import Foundation

public enum CodexUsage {
    public static func fetch() async throws -> [UsageWindow] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/Applications/Codex.app/Contents/Resources"]
        guard let executable = paths.map({ "\($0)/codex" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("Install the Codex CLI, then run codex login with your ChatGPT account.")
        }
        let session = CodexSession(executable: executable)
        return try await withTaskCancellationHandler {
            try await Task.detached { try session.fetch() }.value
        } onCancel: {
            session.stop()
        }
    }
}

// The lock protects subprocess startup and cancellation across the worker and timeout queues.
final class CodexSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var buffer = Data()
    private let timeoutSeconds: TimeInterval

    init(executable: String, timeoutSeconds: TimeInterval = 20) {
        self.timeoutSeconds = timeoutSeconds
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "analytics.enabled=false", "-c", "otel.exporter=\"none\"", "app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func fetch() throws -> [UsageWindow] {
        lock.lock()
        if stopped { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw UsageError.message("Could not start the Codex CLI.") }
        lock.unlock()
        let timeout = DispatchWorkItem { self.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer {
            timeout.cancel()
            stop()
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "usage_bar", "title": "UsageBar", "version": "0.1.0"]]])
        _ = try response(id: 0)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 1, "method": "account/rateLimits/read"])
        return try UsageParser.codex(response(id: 1))
    }

    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func response(id: Int) throws -> Data {
        while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                let message = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                guard message?["id"] as? Int == id else { continue }
                if message?["error"] != nil {
                    throw UsageError.message("Codex could not read subscription limits. Check codex login and try again.")
                }
                guard let result = message?["result"] else { throw UsageError.message("Codex returned an unexpected response.") }
                return try JSONSerialization.data(withJSONObject: result)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw UsageError.message("Codex stopped or took too long to respond. Check codex login and try again.")
            }
            buffer.append(chunk)
            guard buffer.count < 1_048_576 else { throw UsageError.message("Codex returned an oversized response.") }
        }
    }
}
