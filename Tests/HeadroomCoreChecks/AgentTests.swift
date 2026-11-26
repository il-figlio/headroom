import Foundation
import Testing
@testable import HeadroomCore

/// Points a real provider's parser at fixture files the test owns.
private final class FixtureProvider: AgentProvider, ModelTokenTracking {
    let kind: AgentKind
    var files: [URL]
    let wrapped: AgentProvider
    init(kind: AgentKind, files: [URL], wrapped: AgentProvider) {
        self.kind = kind; self.files = files; self.wrapped = wrapped
    }
    var roots: [String] { [] }
    func sessionFiles() -> [URL] { files }
    func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool {
        wrapped.parse(line: line, into: &session, event: &event)
    }
    func takeModelTokens(file: String) -> [String: TokenUsage] {
        (wrapped as? ModelTokenTracking)?.takeModelTokens(file: file) ?? [:]
    }
}

/// Provider parsing, scanner health/offset/usage accounting and the agent
/// tables, on synthetic transcripts in throwaway temp directories.
@Suite struct AgentTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func line(_ json: String) -> Data { Data(json.utf8) }
    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    /// Callers remove it: `defer { try? FileManager.default.removeItem(at: dir) }`.
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ name: String, _ lines: [String], in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func claudeAssistant(id: String = "s1", model: String = "claude-opus-4-6", input: Int = 10, output: Int = 5,
                         cacheRead: Int = 3, cacheWrite: Int = 2, tools: [String] = [],
                         sidechain: Bool = false, at date: Date) -> String {
        let toolBlocks = tools.map { #"{"type":"tool_use","name":"\#($0)"}"# }.joined(separator: ",")
        return #"{"type":"assistant","sessionId":"\#(id)","cwd":"/tmp/proj","isSidechain":\#(sidechain),"timestamp":"\#(iso(date))","message":{"model":"\#(model)","role":"assistant","content":[\#(toolBlocks)],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"#
    }

    @Test func claudeParseAccumulatesUsageAndSkipsSidechainTools() {
        let provider = ClaudeCodeProvider()
        var session = AgentSession(kind: .claude, sessionId: "s1", projectDir: "", filePath: "/tmp/x/s1.jsonl")
        #expect(provider.parse(line: line(#"{"type":"user","sessionId":"s1","cwd":"/tmp/proj","timestamp":"\#(iso(now))"}"#), into: &session))
        _ = provider.parse(line: line(claudeAssistant(tools: ["Bash", "mcp__fs__read"], at: now)), into: &session)
        _ = provider.parse(line: line(claudeAssistant(input: 4, output: 2, cacheRead: 0, cacheWrite: 0, tools: ["Bash"], sidechain: true, at: now)), into: &session)
        #expect(session.projectDir == "/tmp/proj")
        #expect(session.tokens.input == 14)
        #expect(session.tokens.output == 7)
        #expect(session.tokens.cacheRead == 3)
        #expect(session.tokens.cacheWrite == 2)
        #expect(session.tools == ["Bash": 1, "mcp__fs__read": 1])
        #expect(session.models == ["claude-opus-4-6"])
        #expect(session.lastEventAt == now)
        #expect(!provider.parse(line: line("not json"), into: &session))
    }

    @Test func codexRolloutParsesMetaToolsAndCumulativeUsage() {
        let provider = CodexProvider()
        var session = AgentSession(kind: .codex, sessionId: "", projectDir: "", filePath: "/tmp/x/rollout-2026-01-01T00-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/proj"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"turn_context","payload":{"cwd":"/tmp/proj","model":"gpt-9-turbo"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"response_item","payload":{"type":"local_shell_call"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"token_usage_record","payload":{"usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":5,"reasoning_output_tokens":2}}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":5,"reasoning_output_tokens":2}}}}"#), into: &session)
        #expect(session.sessionId == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(session.projectDir == "/tmp/proj")
        #expect(session.models == ["gpt-9-turbo"])
        #expect(session.tools == ["exec_command": 1, "local_shell": 1])
        // Codex counts cached input inside input_tokens and reasoning inside
        // output_tokens: 95 fresh + 5 cached input, 10 output, 110 in all.
        // The per-response delta and the cumulative counter agree, so the
        // counter adds nothing.
        #expect(session.tokens.input == 95)
        #expect(session.tokens.output == 10)
        #expect(session.tokens.cacheRead == 5)
        #expect(session.tokens.total == 110)
        // A later delta resumes accumulating over the cumulative value.
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"token_usage_record","payload":{"usage":{"input_tokens":50,"output_tokens":4}}}"#), into: &session)
        #expect(session.tokens.input == 145)
        #expect(session.tokens.output == 14)
    }

    @Test func genericFallbackAcceptsShapedLinesOnly() {
        let provider = GenericProvider()
        var session = AgentSession(kind: .other, sessionId: "g1", projectDir: "", filePath: "/tmp/x/g1.jsonl")
        #expect(provider.parse(line: line(#"{"type":"message","role":"assistant","timestamp":"\#(iso(now))","model":"m1","usage":{"prompt_tokens":7,"completion_tokens":3}}"#), into: &session))
        #expect(session.tokens.input == 7)
        #expect(session.tokens.output == 3)
        #expect(session.models == ["m1"])
        #expect(session.lastEventAt == now)
        #expect(!provider.parse(line: line(#"{"type":"message"}"#), into: &session))
        #expect(!provider.parse(line: line(#"{"timestamp":"\#(iso(now))"}"#), into: &session))
        #expect(!provider.parse(line: line("hello"), into: &session))
    }

    @Test func toolTaxonomyAndPricing() {
        #expect(ToolTaxonomy.categorize("Bash") == .shell)
        #expect(ToolTaxonomy.categorize("mcp__github__list") == .mcp)
        #expect(ToolTaxonomy.categorize("send_message") == .message)
        #expect(AgentPricing.rate(for: "claude-opus-4-6") != nil)
        #expect(AgentPricing.cost(TokenUsage(), model: "claude-sonnet-4-7") != nil)
        #expect(AgentPricing.rate(for: "gpt-9-turbo") == nil)
        #expect(AgentPricing.cost(TokenUsage(), model: "gpt-9-turbo") == nil)
    }

    private func makeScanner(for provider: FixtureProvider, in dir: URL) -> AgentScanner {
        AgentScanner(providers: [provider], roots: [(kind: provider.kind, path: dir.path)])
    }

    @Test func healthTransitions() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try write("a.jsonl", [#"{"type":"user","sessionId":"a","cwd":"/tmp/p","timestamp":"\#(iso(now))"}"#,
                                          claudeAssistant(id: "a", at: now)], in: dir)
        let stale = try write("b.jsonl", [#"{"type":"user","sessionId":"b","cwd":"/tmp/q","timestamp":"\#(iso(now.addingTimeInterval(-3600)))"}"#], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [fresh, stale], wrapped: ClaudeCodeProvider())
        let scanner = makeScanner(for: provider, in: dir)
        let alive = [AgentProcess(pid: 4242, args: "/usr/local/bin/claude")]

        var result = scanner.scan(now: now, processes: alive)
        let byID = Dictionary(result.snapshot.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        // Single candidate process: the fresh session gets it and goes live.
        #expect(byID["a"]?.health == .live)
        #expect(byID["a"]?.pid == 4242)
        #expect(byID["b"]?.health == .ended)

        // Args correlating to the stale session's project dir → pid, stale → stuck.
        let staleProvider = FixtureProvider(kind: .claude, files: [stale], wrapped: ClaudeCodeProvider())
        let correlated = [AgentProcess(pid: 4343, args: "claude --cwd /tmp/q")]
        result = makeScanner(for: staleProvider, in: dir).scan(now: now, processes: correlated)
        let staleSession = result.snapshot.sessions.first { $0.sessionId == "b" }
        #expect(staleSession?.pid == 4343)
        #expect(staleSession?.health == .stuck)

        // No process + growth between scans → zombie; no growth → ended.
        var result2 = scanner.scan(now: now, processes: [])
        let handle = try FileHandle(forWritingTo: fresh)
        try handle.seekToEnd()
        handle.write(Data((#"{"type":"user","sessionId":"a","timestamp":"\#(iso(now.addingTimeInterval(-1200)))"}"# + "\n").utf8))
        try handle.close()
        result2 = scanner.scan(now: now, previousSessions: result2.sessions, offsets: result2.offsets, processes: [])
        #expect(result2.snapshot.sessions.first { $0.sessionId == "a" }?.health == .zombie)
        #expect(result2.snapshot.sessions.first { $0.sessionId == "b" }?.health == .ended)
    }

    @Test func offsetResumeReadsOnlyNewLines() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write("s.jsonl", [claudeAssistant(input: 10, output: 5, tools: ["Bash"], at: now)], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [file], wrapped: ClaudeCodeProvider())
        let scanner = makeScanner(for: provider, in: dir)

        let first = scanner.scan(now: now, processes: [])
        #expect(first.snapshot.sessions.first?.tokens.input == 10)
        let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        #expect(first.offsets[file.path] == size)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((claudeAssistant(input: 20, output: 8, tools: ["Read"], at: now) + "\n").utf8))
        try handle.close()

        let second = scanner.scan(now: now, previousSessions: first.sessions, offsets: first.offsets, processes: [])
        let session = try #require(second.snapshot.sessions.first)
        #expect(session.tokens.input == 30)
        #expect(session.tokens.output == 13)
        #expect(session.tools == ["Bash": 1, "Read": 1])
        #expect(second.offsets[file.path] ?? 0 == size + Int64(claudeAssistant(input: 20, output: 8, tools: ["Read"], at: now).utf8.count + 1))
        // claude-opus-4-6 is priced, so cost accumulates and nothing is unpriced.
        #expect(session.unpricedTokens == 0)
        #expect((session.costUSD ?? 0) > 0)
    }

    @Test func scanUsageCountsEachLineOnce() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write("s.jsonl", [claudeAssistant(input: 10, output: 5, at: now)], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [file], wrapped: ClaudeCodeProvider())
        let scanner = makeScanner(for: provider, in: dir)

        // 10 + 5 + 3 + 2 = 20 tokens; `now` is already hour-aligned.
        let first = scanner.scan(now: now, processes: [])
        #expect(first.usage.count == 1)
        #expect(first.usage.first?.hour == now)
        #expect(first.usage.first?.tokens[.claude] == 20)
        // claude-opus-4-6 is priced: (10*5 + 5*25 + 3*0.5 + 2*6.25)/1e6.
        #expect(abs((first.usage.first?.cost[.claude] ?? -1) - 0.000189) < 1e-9)

        // Rescanning the same bytes contributes nothing — offsets dedupe.
        let second = scanner.scan(now: now, previousSessions: first.sessions, offsets: first.offsets, processes: [])
        #expect(second.usage.isEmpty)

        // An appended line adds exactly its own usage to the same bucket.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((claudeAssistant(input: 4, output: 2, cacheRead: 0, cacheWrite: 0, at: now.addingTimeInterval(120)) + "\n").utf8))
        try handle.close()
        let third = scanner.scan(now: now, previousSessions: second.sessions, offsets: second.offsets, processes: [])
        #expect(third.usage.count == 1)
        #expect(third.usage.first?.hour == now)
        #expect(third.usage.first?.tokens[.claude] == 6)
        #expect(abs((third.usage.first?.cost[.claude] ?? -1) - 0.00007) < 1e-9)
    }

    @Test func scanUsageSplitsEventsAcrossHours() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // `now` is hour-aligned, so one minute either side lands in
        // adjacent buckets — this also exercises truncation.
        let file = try write("s.jsonl", [
            claudeAssistant(input: 10, output: 0, cacheRead: 0, cacheWrite: 0, at: now.addingTimeInterval(-60)),
            claudeAssistant(input: 0, output: 7, cacheRead: 0, cacheWrite: 0, at: now.addingTimeInterval(60)),
        ], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [file], wrapped: ClaudeCodeProvider())
        let result = makeScanner(for: provider, in: dir).scan(now: now, processes: [])
        #expect(result.usage.count == 2)
        #expect(result.usage[0].hour == now.addingTimeInterval(-3600))
        #expect(result.usage[0].tokens[.claude] == 10)
        #expect(result.usage[1].hour == now)
        #expect(result.usage[1].tokens[.claude] == 7)
    }

    @Test func agentUsageRecordAndLoadAccumulates() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        // The store deletes agent_usage rows older than 30 days by the real
        // clock whenever it writes, so these hours are taken from it.
        let now = AgentScanner.hourBucket(Date())
        var first = HourBurn(hour: now)
        first.tokens[.claude] = 20
        first.cost[.claude] = 0.010
        first.tokens[.codex] = 5 // unpriced — no cost entry expected
        try store.recordAgentUsage([first])
        var second = HourBurn(hour: now)
        second.tokens[.claude] = 6
        second.cost[.claude] = 0.004
        var later = HourBurn(hour: now.addingTimeInterval(3600))
        later.tokens[.claude] = 1
        try store.recordAgentUsage([second, later])

        let loaded = try store.loadAgentUsage(since: now.addingTimeInterval(-1800))
        #expect(loaded.map(\.hour) == [now, now.addingTimeInterval(3600)])
        #expect(loaded[0].tokens[.claude] == 26)
        #expect(loaded[0].tokens[.codex] == 5)
        #expect(abs((loaded[0].cost[.claude] ?? -1) - 0.014) < 1e-9)
        #expect(loaded[0].cost[.codex] == nil)
        #expect(loaded[1].tokens[.claude] == 1)
        #expect(loaded[1].cost[.claude] == nil)

        // A `since` inside a bucket still returns that bucket; past it drops.
        let mid = try store.loadAgentUsage(since: now.addingTimeInterval(600))
        #expect(mid.map(\.hour) == [now, now.addingTimeInterval(3600)])
        let tail = try store.loadAgentUsage(since: now.addingTimeInterval(3600 + 600))
        #expect(tail.map(\.hour) == [now.addingTimeInterval(3600)])
    }

    @Test func historyStoresSessionsAndOffsets() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        var session = AgentSession(kind: .claude, sessionId: "s1", projectDir: "/tmp/p", filePath: "/tmp/f.jsonl")
        session.pid = 99
        session.startedAt = now.addingTimeInterval(-100)
        session.lastEventAt = now
        session.models = ["claude-opus-4-6"]
        session.tokens.input = 42
        session.tools = ["Bash": 3]
        session.costUSD = 0.5
        session.health = .live
        try store.saveAgentSessions([session], offsets: ["/tmp/f.jsonl": 1234])
        try store.saveScanOffsets(["/tmp/f.jsonl": 1234])
        let loaded = try #require(store.loadAgentSessions().first)
        #expect(loaded.id == "claude:s1")
        #expect(loaded.pid == 99)
        #expect(loaded.tokens.input == 42)
        #expect(loaded.tools == ["Bash": 3])
        #expect(loaded.costUSD == 0.5)
        #expect(loaded.health == .live)
        #expect(try store.loadScanOffsets() == ["/tmp/f.jsonl": 1234])
    }
}
