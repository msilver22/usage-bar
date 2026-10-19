import Foundation
import Testing
@testable import UsageCore

@Test func codexUsesCorrectBucketAndWindowLengths() throws {
    let windows = try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":60}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":62,"windowDurationMins":10080}}}}"#.utf8))
    #expect(windows.map(\.id) == ["5 hours", "Week"])
    #expect(windows.map(\.usedPercent) == [25, 62])
    #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1800000000))
}

@Test func codexDoesNotInventWeeklyData() throws {
    let windows = try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":15},"secondary":null}}"#.utf8))
    #expect(windows.count == 1)
    #expect(windows[0].id == "15 minutes")
    #expect(windows[0].usedPercent == 0)
}

@Test func claudeParsesBothTimestampFormats() throws {
    let windows = try UsageParser.claude(Data(#"{"five_hour":{"utilization":12.5,"resets_at":"2026-10-19T18:00:00.123Z"},"seven_day":{"utilization":80,"resets_at":"2026-10-22T12:00:00Z"}}"#.utf8))
    #expect(windows.map(\.usedPercent) == [12.5, 80])
    #expect(windows.allSatisfy { $0.resetsAt != nil })
}

@Test func missingClaudeWindowIsUnavailableRatherThanZero() throws {
    let windows = try UsageParser.claude(Data(#"{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}"#.utf8))
    #expect(windows[0].usedPercent == nil)
    #expect(windows[1].usedPercent == 0)
}

@Test func malformedPayloadsFailClearly() {
    #expect(throws: (any Error).self) { try UsageParser.codex(Data("{}".utf8)) }
    #expect(throws: (any Error).self) { try UsageParser.claude(Data("{}".utf8)) }
    #expect(throws: (any Error).self) {
        try UsageParser.claude(Data(#"{"five_hour":{"utilization":20,"resets_at":"tomorrow"}}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":-1}}}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        try UsageParser.claude(Data(#"{"five_hour":{"utilization":101}}"#.utf8))
    }
}

private func withExecutable(_ body: String, run: (String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fake-codex")
    try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try run(script.path)
}

@Test func codexHandshakeIgnoresNotificationsAndStopsProcess() throws {
    try withExecutable("""
    IFS= read -r initialize
    printf '%s\n' '{"method":"some/notification"}' '{"id":0,"result":{}}'
    IFS= read -r initialized
    IFS= read -r request
    printf '%s\n' '{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300}}}}'
    exec /bin/sleep 10
    """) { path in
        let start = Date()
        let windows = try CodexSession(executable: path, timeoutSeconds: 2).fetch()
        #expect(windows[0].usedPercent == 42)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Test func codexTimeoutAndCancellationDoNotHang() throws {
    try withExecutable("exec /bin/sleep 10\n") { path in
        let start = Date()
        #expect(throws: (any Error).self) { try CodexSession(executable: path, timeoutSeconds: 0.1).fetch() }
        #expect(Date().timeIntervalSince(start) < 2)
        let cancelled = CodexSession(executable: path)
        cancelled.stop()
        #expect(throws: CancellationError.self) { try cancelled.fetch() }
    }
}

@Test func codexErrorResponseDoesNotLeakServerDetails() throws {
    try withExecutable("""
    IFS= read -r initialize
    printf '%s\n' '{"id":0,"error":{"message":"secret-server-details"}}'
    """) { path in
        do {
            _ = try CodexSession(executable: path).fetch()
            Issue.record("Expected the RPC error to fail")
        } catch {
            #expect(!error.localizedDescription.contains("secret-server-details"))
        }
    }
}
