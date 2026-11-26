import Foundation
import Testing
@testable import HeadroomCore

/// What counts as a token: Codex and Claude Code usage shapes and duplicate
/// responses. Synthetic transcripts in throwaway temp directories only.
@Suite struct AgentAccountingChecks {
    let now = Date(timeIntervalSince1970: 1_795_521_600) // 2026-11-24T12:00:00Z

    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-accounting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func append(_ url: URL, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func tokens(_ usage: [HourBurn]) -> Int64 {
        usage.reduce(0) { $0 + $1.tokens.values.reduce(0, +) }
    }

    func usage(_ json: String) throws -> TokenUsage {
        AgentLine.usage(try #require(AgentLine.dict(Data(json.utf8))))
    }

    /// One Claude Code assistant line. `id`/`request` are the message id and
    /// the top-level request id that repeat across a response's lines.
    func claudeLine(id: String? = nil, request: String? = nil, at date: Date? = nil, input: Int = 10, output: Int = 5,
                    tool: String? = nil, model: String = "claude-sonnet-4-5") -> Data {
        let requestField = request.map { #""requestId":"\#($0)","# } ?? ""
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        let content = tool.map { #"[{"type":"tool_use","name":"\#($0)"}]"# } ?? "[]"
        return Data((#"{"type":"assistant",\#(requestField)"timestamp":"\#(stamp(date ?? now.addingTimeInterval(-60)))","message":{\#(idField)"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"content":\#(content)}}"# + "\n").utf8)
    }

    /// A Claude home with one project folder; returns the scanner and the
    /// project directory transcripts go in. Each scanner has its own provider.
    func claudeHome(_ root: URL) throws -> (scanner: AgentScanner, project: URL) {
        let project = root.appendingPathComponent("projects/-Users-me-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let scanner = AgentScanner(providers: [ClaudeCodeProvider(root: root.path), GenericProvider()], roots: [(.claude, root.path)])
        return (scanner, project)
    }

    /// Carries scan state forward the way the monitor does.
    struct Chain {
        var sessions: [AgentSession] = []
        var offsets: [String: Int64] = [:]
        var identities: [String: AgentFileID] = [:]
        var burn: Int64 = 0

        @discardableResult
        mutating func scan(_ scanner: AgentScanner, now: Date) -> AgentScanResult {
            let result = scanner.scan(now: now, previousSessions: sessions, offsets: offsets, identities: identities, processes: [])
            sessions = result.sessions; offsets = result.offsets; identities = result.identities
            burn += result.usage.reduce(0) { $0 + $1.tokens.values.reduce(0, +) }
            return result
        }
    }

    // MARK: Usage shapes

    /// Codex: cached input is part of input_tokens and reasoning output is
    /// part of output_tokens, so neither is added on top.
    @Test func codexUsageCountsCachedAndReasoningTokensOnce() throws {
        let u = try usage(#"{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":30,"total_tokens":1050}"#)
        #expect(u.input == 200)
        #expect(u.cacheRead == 800)
        #expect(u.output == 50)
        #expect(u.cacheWrite == 0)
        #expect(u.total == 1050)
        // Newer Codex also reports cache writes, again as part of input
        // (upstream's own example: 100 input = 40 cached + 60 written).
        let written = try usage(#"{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":60,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":110}"#)
        #expect(written.input == 0)
        #expect(written.cacheRead == 40)
        #expect(written.cacheWrite == 60)
        #expect(written.output == 10)
        #expect(written.total == 110)
        // More cached than input can't be real; input floors at zero.
        let odd = try usage(#"{"input_tokens":10,"cached_input_tokens":50,"output_tokens":1}"#)
        #expect(odd.input == 0)
        #expect(odd.cacheRead == 50)
    }

    /// Claude: cache reads and writes are reported apart from input_tokens.
    @Test func claudeUsageKeepsCacheFieldsApartFromInput() throws {
        let u = try usage(#"{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":300,"cache_creation_input_tokens":20}"#)
        #expect(u.input == 10)
        #expect(u.output == 5)
        #expect(u.cacheRead == 300)
        #expect(u.cacheWrite == 20)
        #expect(u.total == 335)
    }

    /// The cumulative counter path: each `token_count` adds only its jump
    /// over the last one, in the same normalised fields.
    @Test func codexCumulativeCountsAddOnlyTheirIncrease() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/2026/11/24/rollout-2026-11-24T10-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func count(_ at: String, _ total: String) -> Data {
            Data((#"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(total)}}}"# + "\n").utf8)
        }
        try count("2026-11-24T10:00:00Z", #"{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":30}"#).write(to: file)
        let scanner = AgentScanner(providers: [CodexProvider(root: root.path), GenericProvider()], roots: [(.codex, root.path)])
        var chain = Chain()
        chain.scan(scanner, now: now)
        #expect(chain.burn == 1050)
        try append(file, count("2026-11-24T10:05:00Z", #"{"input_tokens":2500,"cached_input_tokens":2000,"output_tokens":120,"reasoning_output_tokens":60}"#))
        // The same counter again changes nothing.
        try append(file, count("2026-11-24T10:05:01Z", #"{"input_tokens":2500,"cached_input_tokens":2000,"output_tokens":120,"reasoning_output_tokens":60}"#))
        chain.scan(scanner, now: now)
        let session = try #require(chain.sessions.first)
        #expect(session.tokens.input == 500)
        #expect(session.tokens.cacheRead == 2000)
        #expect(session.tokens.output == 120)
        #expect(session.tokens.total == 2620)
        #expect(chain.burn == 2620)
    }

    /// A session saved by a build that counted cached and reasoning tokens
    /// twice adds nothing until the real counter passes it, then follows it.
    @Test func codexSessionSavedWithDoubleCountsSettlesOnTheCounter() {
        let provider = CodexProvider(root: "/nonexistent")
        var session = AgentSession(kind: .codex, sessionId: "s", projectDir: "", filePath: "/nonexistent/rollout-x.jsonl")
        session.tokens.input = 100; session.tokens.cacheRead = 5; session.tokens.output = 12 // 117; really 95 + 5 + 10
        func count(_ total: String) -> Data {
            Data(#"{"timestamp":"2026-11-24T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(total)}}}"#.utf8)
        }
        var event = AgentLineEvent()
        _ = provider.parse(line: count(#"{"input_tokens":100,"cached_input_tokens":5,"output_tokens":10,"reasoning_output_tokens":2}"#), into: &session, event: &event)
        #expect(event.tokens.total == 0)
        #expect(session.tokens.total == 117)
        _ = provider.parse(line: count(#"{"input_tokens":300,"cached_input_tokens":100,"output_tokens":40,"reasoning_output_tokens":9}"#), into: &session, event: &event)
        #expect(session.tokens.input == 200)
        #expect(session.tokens.cacheRead == 100)
        #expect(session.tokens.output == 40)
        #expect(session.tokens.total == 340)
    }

    // MARK: Claude Code duplicate responses

    /// One response written as three lines (one per content block): usage
    /// once, tools from every line.
    @Test func claudeResponseSpreadOverLinesIsCountedOnce() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (scanner, project) = try claudeHome(root)
        let lines = claudeLine(id: "msg_1", request: "req_1")
            + claudeLine(id: "msg_1", request: "req_1", tool: "Read")
            + claudeLine(id: "msg_1", request: "req_1", tool: "Bash")
            + claudeLine(id: "msg_2", request: "req_2", tool: "Read")
        try lines.write(to: project.appendingPathComponent("s.jsonl"))
        let result = scanner.scan(now: now, processes: [])
        let session = try #require(result.sessions.first)
        #expect(session.tokens.total == 30)
        #expect(session.tokens.input == 20)
        #expect(session.tools == ["Read": 2, "Bash": 1])
        #expect(tokens(result.usage) == 30)
        // claude-sonnet-4-5: (20 * 3 + 10 * 15) / 1e6.
        #expect(abs((session.costUSD ?? -1) - 0.00021) < 1e-12)
        #expect(session.unpricedTokens == 0)
    }

    /// The scanner reads tails incrementally, so the repeat can arrive in a
    /// later scan than the line it repeats.
    @Test func claudeDuplicateInALaterScanAddsNothing() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (scanner, project) = try claudeHome(root)
        let file = project.appendingPathComponent("s.jsonl")
        try claudeLine(id: "msg_1", request: "req_1").write(to: file)
        var chain = Chain()
        chain.scan(scanner, now: now)
        #expect(chain.burn == 15)
        try append(file, claudeLine(id: "msg_1", request: "req_1", tool: "Edit"))
        let second = chain.scan(scanner, now: now)
        #expect(second.usage.isEmpty)
        #expect(chain.sessions.first?.tokens.total == 15)
        #expect(chain.sessions.first?.tools == ["Edit": 1])
    }

    @Test func claudeDuplicatesFallBackToMessageIdAndNeedOne() {
        let provider = ClaudeCodeProvider(root: "/nonexistent")
        var session = AgentSession(kind: .claude, sessionId: "s", projectDir: "", filePath: "/nonexistent/s.jsonl")
        // No requestId: the message id alone identifies the response.
        _ = provider.parse(line: claudeLine(id: "msg_1"), into: &session)
        _ = provider.parse(line: claudeLine(id: "msg_1"), into: &session)
        #expect(session.tokens.total == 15)
        // The same message id under another request is another response.
        _ = provider.parse(line: claudeLine(id: "msg_2", request: "req_a"), into: &session)
        _ = provider.parse(line: claudeLine(id: "msg_2", request: "req_b"), into: &session)
        #expect(session.tokens.total == 45)
        // No message id: nothing to match on, so each line counts as before.
        _ = provider.parse(line: claudeLine(request: "req_c"), into: &session)
        _ = provider.parse(line: claudeLine(request: "req_c"), into: &session)
        #expect(session.tokens.total == 75)
    }

    /// A later line for the same response reporting more (a streaming
    /// snapshot) adds only the increase, to the session, the hourly burn and
    /// the per-model cost alike.
    @Test func claudeLaterLargerSnapshotAddsOnlyTheDifference() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (scanner, project) = try claudeHome(root)
        let file = project.appendingPathComponent("s.jsonl")
        try (claudeLine(id: "msg_1", request: "req_1", input: 1_000_000, output: 100)
            + claudeLine(id: "msg_1", request: "req_1", input: 1_000_000, output: 1_000_100)).write(to: file)
        var chain = Chain()
        let first = chain.scan(scanner, now: now)
        #expect(chain.sessions.first?.tokens.input == 1_000_000)
        #expect(chain.sessions.first?.tokens.output == 1_000_100)
        #expect(tokens(first.usage) == 2_000_100)
        // $3 input + $15.0015 output on claude-sonnet-4-5.
        #expect(abs((chain.sessions.first?.costUSD ?? -1) - 18.0015) < 1e-9)
        // A smaller, stale snapshot afterwards takes nothing back.
        try append(file, claudeLine(id: "msg_1", request: "req_1", input: 1_000_000, output: 50))
        #expect(chain.scan(scanner, now: now).usage.isEmpty)
        #expect(chain.sessions.first?.tokens.total == 2_000_100)
    }

    /// A resumed or forked session copies earlier messages into its own
    /// file; they are the same responses and count once overall.
    @Test func claudeResponseCopiedIntoAnotherTranscriptIsCountedOnce() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (scanner, project) = try claudeHome(root)
        let original = project.appendingPathComponent("a.jsonl")
        try (claudeLine(id: "msg_1", request: "req_1") + claudeLine(id: "msg_2", request: "req_2")).write(to: original)
        var chain = Chain()
        chain.scan(scanner, now: now)
        #expect(chain.burn == 30)
        let fork = project.appendingPathComponent("b.jsonl")
        try (claudeLine(id: "msg_1", request: "req_1") + claudeLine(id: "msg_2", request: "req_2")
            + claudeLine(id: "msg_3", request: "req_3")).write(to: fork)
        chain.scan(scanner, now: now)
        #expect(chain.burn == 45)
        let byFile = Dictionary(uniqueKeysWithValues: chain.sessions.map { (URL(fileURLWithPath: $0.filePath).lastPathComponent, $0.tokens.total) })
        #expect(byFile == ["a.jsonl": 30, "b.jsonl": 15])
    }

    /// A scan whose results couldn't be saved is repeated from the previous
    /// state and reads the same bytes again. Those are the same lines, not
    /// duplicates, and must count in full each time.
    @Test func claudeRereadOfTheSameBytesCountsInFull() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (scanner, project) = try claudeHome(root)
        let file = project.appendingPathComponent("s.jsonl")
        try (claudeLine(id: "msg_1", request: "req_1", output: 5)
            + claudeLine(id: "msg_1", request: "req_1", output: 9)
            + claudeLine(id: "msg_2", request: "req_2")).write(to: file)
        let first = scanner.scan(now: now, processes: [])
        #expect(tokens(first.usage) == 34)
        // The whole file again, from nothing.
        let retry = scanner.scan(now: now, processes: [])
        #expect(tokens(retry.usage) == 34)
        #expect(retry.sessions.first?.tokens.total == 34)

        // Only the tail again: a later snapshot of msg_2 arrives, its scan is
        // lost, and the retry starts from the state before it.
        try append(file, claudeLine(id: "msg_2", request: "req_2", output: 25))
        let lost = scanner.scan(now: now, previousSessions: retry.sessions, offsets: retry.offsets, identities: retry.identities, processes: [])
        let again = scanner.scan(now: now, previousSessions: retry.sessions, offsets: retry.offsets, identities: retry.identities, processes: [])
        #expect(tokens(lost.usage) == 20)
        #expect(tokens(again.usage) == 20)
        #expect(again.sessions.first?.tokens.total == 54)
    }

    /// The memory of counted responses is bounded: the oldest is forgotten
    /// first, and a forgotten response counts again if it reappears.
    @Test func messageUsageLedgerIsBounded() {
        var ledger = MessageUsageLedger(limit: 2)
        var ten = TokenUsage(); ten.input = 10
        func count(_ ledger: inout MessageUsageLedger, _ id: String) -> Int64 {
            ledger.uncounted(ten, message: id, request: "r", file: "/f", offset: nil).total
        }
        #expect(count(&ledger, "a") == 10)
        #expect(count(&ledger, "b") == 10)
        #expect(count(&ledger, "a") == 0)
        #expect(count(&ledger, "c") == 10)
        #expect(ledger.count == 2)
        #expect(count(&ledger, "c") == 0)
        #expect(count(&ledger, "b") == 0)
        #expect(count(&ledger, "a") == 10) // forgotten; evicts b
        for index in 0..<1000 { _ = count(&ledger, "m\(index)") }
        #expect(ledger.count == 2)
        #expect(count(&ledger, "m999") == 0)
    }
}
