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
    /// Checks `remoteURL` directly without touching TCC-protected folders like `~/Documents`.
    public static func check(
        remoteURL: String,
        upstreamCommit: String,
        branch: String = "main",
        timeoutSeconds: TimeInterval = 15
    ) throws -> UpdateStatus {
        let lsRemote = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["ls-remote", remoteURL, "refs/heads/\(branch)"],
            workingDirectory: FileManager.default.temporaryDirectory,
            timeoutSeconds: timeoutSeconds,
            captureOutput: true
        )
        guard lsRemote.status == 0 else {
            throw UsageError.message("Could not reach \(branch) to check for updates.")
        }
        guard let remoteCommit = parseRemoteCommit(lsRemote.output) else {
            throw UsageError.message("Could not read the latest commit on \(branch).")
        }
        return remoteCommit == upstreamCommit
            ? .upToDate
            : .available(UpdateInfo(currentCommit: upstreamCommit, remoteCommit: remoteCommit))
    }

    public static func parseRemoteCommit(_ output: String) -> String? {
        guard let token = output.split(whereSeparator: \.isWhitespace).first else { return nil }
        let sha = String(token)
        guard sha.count >= 7, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }

    /// Clones or fast-forwards a clean mirror in `Application Support/UsageBar/repo` and builds `dist/UsageBar.app`.
    public static func prepareUpdate(
        remoteURL: String,
        branch: String = "main",
        workDir: String? = nil,
        timeoutSeconds: TimeInterval = 300
    ) throws -> String {
        let repoDir: URL
        if let workDir {
            repoDir = URL(fileURLWithPath: workDir)
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw UsageError.message("Could not locate Application Support directory.")
            }
            repoDir = appSupport.appendingPathComponent("UsageBar/repo")
        }

        let parentDir = repoDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let gitDir = repoDir.appendingPathComponent(".git").path
        if FileManager.default.fileExists(atPath: gitDir) {
            try runChecked(
                executable: "/usr/bin/git",
                arguments: ["-C", repoDir.path, "remote", "set-url", "origin", remoteURL],
                workingDirectory: parentDir,
                timeoutSeconds: 30,
                failureMessage: "Failed to configure update remote."
            )
            try runChecked(
                executable: "/usr/bin/git",
                arguments: ["-C", repoDir.path, "fetch", "origin", branch],
                workingDirectory: parentDir,
                timeoutSeconds: 60,
                failureMessage: "Failed to fetch latest \(branch)."
            )
            try runChecked(
                executable: "/usr/bin/git",
                arguments: ["-C", repoDir.path, "reset", "--hard", "origin/\(branch)"],
                workingDirectory: parentDir,
                timeoutSeconds: 30,
                failureMessage: "Failed to switch to latest \(branch)."
            )
        } else {
            try? FileManager.default.removeItem(at: repoDir)
            try runChecked(
                executable: "/usr/bin/git",
                arguments: ["clone", "--branch", branch, "--single-branch", remoteURL, repoDir.path],
                workingDirectory: parentDir,
                timeoutSeconds: 120,
                failureMessage: "Failed to clone repository for update."
            )
        }

        let buildScript = repoDir.appendingPathComponent("scripts/build-app.sh").path
        try runChecked(
            executable: "/bin/bash",
            arguments: [buildScript],
            workingDirectory: repoDir,
            timeoutSeconds: timeoutSeconds,
            failureMessage: "Build failed while updating."
        )

        let builtApp = repoDir.appendingPathComponent("dist/UsageBar.app").path
        guard FileManager.default.fileExists(atPath: builtApp) else {
            throw UsageError.message("Build finished, but UsageBar.app was not found.")
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
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private static func runChecked(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: TimeInterval,
        failureMessage: String
    ) throws {
        let result = try runProcess(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            captureOutput: true,
            combineStderr: true
        )
        guard result.status == 0 else {
            let detail = result.output
                .split(whereSeparator: \.isNewline)
                .last
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            throw UsageError.message(detail.flatMap { $0.isEmpty ? nil : $0 } ?? failureMessage)
        }
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: TimeInterval,
        captureOutput: Bool,
        combineStderr: Bool = false
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
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
