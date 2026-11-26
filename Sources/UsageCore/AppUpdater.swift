import Foundation

public struct UpdateInfo: Equatable, Sendable {
    public let currentCommit: String
    public let remoteCommit: String

    public var shortRemoteCommit: String { String(remoteCommit.prefix(7)) }

    public init(currentCommit: String, remoteCommit: String) {
        self.currentCommit = currentCommit
        self.remoteCommit = remoteCommit
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(UpdateInfo)
}

public enum AppUpdater {
    public static func check(
        repoPath: String,
        builtCommit: String,
        remote: String = "origin",
        branch: String = "main",
        timeoutSeconds: TimeInterval = 15
    ) throws -> UpdateStatus {
        let lsRemote = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", repoPath, "ls-remote", remote, "refs/heads/\(branch)"],
            timeoutSeconds: timeoutSeconds,
            captureOutput: true
        )
        guard lsRemote.status == 0 else {
            throw UsageError.message("Could not reach \(remote)/\(branch) to check for updates.")
        }
        guard let remoteCommit = parseRemoteCommit(lsRemote.output) else {
            throw UsageError.message("Could not read the latest commit on \(remote)/\(branch).")
        }
        if remoteCommit == builtCommit { return .upToDate }

        // Treats local commits rebased on top of remoteCommit as up to date; un-fetched or newer remote commits return nonzero.
        let ancestor = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", repoPath, "merge-base", "--is-ancestor", remoteCommit, builtCommit],
            timeoutSeconds: timeoutSeconds,
            captureOutput: false
        )
        return ancestor.status == 0
            ? .upToDate
            : .available(UpdateInfo(currentCommit: builtCommit, remoteCommit: remoteCommit))
    }

    public static func parseRemoteCommit(_ output: String) -> String? {
        guard let token = output.split(whereSeparator: \.isWhitespace).first else { return nil }
        let sha = String(token)
        guard sha.count >= 7, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }

    /// Pulls latest main and rebuilds `dist/UsageBar.app`, returning the built bundle path.
    public static func prepareUpdate(repoPath: String, timeoutSeconds: TimeInterval = 300) throws -> String {
        let script = URL(fileURLWithPath: repoPath).appendingPathComponent("scripts/update-app.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            throw UsageError.message("Update script not found at \(script).")
        }
        let result = try runProcess(
            executable: "/bin/bash",
            arguments: [script],
            timeoutSeconds: timeoutSeconds,
            captureOutput: true,
            combineStderr: true
        )
        guard result.status == 0 else {
            let detail = result.output
                .split(whereSeparator: \.isNewline)
                .last
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            throw UsageError.message(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Update failed while pulling or rebuilding.")
        }
        let builtApp = URL(fileURLWithPath: repoPath).appendingPathComponent("dist/UsageBar.app").path
        guard FileManager.default.fileExists(atPath: builtApp) else {
            throw UsageError.message("Build finished, but \(builtApp) was not found.")
        }
        return builtApp
    }

    /// Spawns a detached helper that waits for `pid` to exit, replaces `targetAppPath`, and relaunches it.
    public static func relaunch(builtAppPath: String, targetAppPath: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        guard targetAppPath.hasSuffix(".app"), FileManager.default.fileExists(atPath: builtAppPath) else {
            throw UsageError.message("Cannot replace app bundle at \(targetAppPath).")
        }
        let script = """
        built="$1"; target="$2"; pid="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        if [ "$built" != "$target" ]; then
            stage="${target}.updating"
            rm -rf "$stage"
            if /usr/bin/ditto "$built" "$stage"; then
                rm -rf "$target" && mv "$stage" "$target"
            else
                rm -rf "$stage"
                exit 1
            fi
        fi
        /usr/bin/open "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "_", builtAppPath, targetAppPath, String(pid)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        captureOutput: Bool,
        combineStderr: Bool = false
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let basePath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = environment["PATH"].map { "\($0):\(basePath)" } ?? basePath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = captureOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = combineStderr ? (pipe ?? FileHandle.nullDevice) : FileHandle.nullDevice

        try process.run()
        let timedOut = LockedFlag()
        let timeout = DispatchWorkItem {
            timedOut.set()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? pipe?.fileHandleForReading.close()
        }

        let outputData = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        if timedOut.isSet {
            throw UsageError.message("Update operation timed out.")
        }
        return ProcessResult(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
