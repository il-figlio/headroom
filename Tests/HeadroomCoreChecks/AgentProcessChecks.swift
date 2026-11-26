import Foundation
import Testing
@testable import HeadroomCore

/// The process list behind session health: the real `ps` (which only lists
/// processes), fake `ps` scripts in throwaway temp directories, and scans
/// that are told the list is unavailable.
@Suite struct AgentProcessChecks {
    let now = Date(timeIntervalSince1970: 1_795_521_600) // 2026-11-24T12:00:00Z
    let fast = BoundedProcess.Limits(timeout: 0.5, killGrace: 0.3)

    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-ps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An executable shell script standing in for `ps`.
    func fakePS(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("ps")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func stamp(_ ago: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago))
    }

    func usageLine(_ ago: TimeInterval) -> Data {
        Data((#"{"type":"assistant","timestamp":""# + stamp(ago) + #"","model":"m","usage":{"input_tokens":7,"output_tokens":3}}"# + "\n").utf8)
    }

    func append(_ url: URL, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// The real thing: /bin/ps launches, its output (far more than a pipe
    /// holds) is read to the end, and this test process is in it.
    @Test func liveProcessListIncludesThisProcess() throws {
        let processes = try #require(AgentScanner.liveProcesses())
        let own = processes.first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        #expect(own != nil)
        #expect(own?.args.isEmpty == false)
        #expect(processes.count > 1)
    }

    @Test func processListParsesPidAndFullArguments() {
        let parsed = AgentScanner.parseProcessList(Data("    1 /sbin/launchd\n 4242 node /opt/bin/claude --resume  x\n\nnot a row\n77\n".utf8))
        #expect(parsed.map(\.pid) == [1, 4242])
        #expect(parsed.last?.args == "node /opt/bin/claude --resume  x")
    }

    /// Output several times the 64 KiB pipe buffer: reading only after the
    /// child exits would block both sides forever.
    @Test func processListLargerThanAPipeIsReadInFull() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let filler = String(repeating: "x", count: 200)
        let ps = try fakePS("i=1; while [ $i -le 2000 ]; do echo \"$i /usr/local/bin/tool \(filler)\"; i=$((i+1)); done", in: dir)
        let processes = try #require(AgentScanner.liveProcesses(executable: ps, limits: AgentScanner.psLimits))
        #expect(processes.count == 2000)
        #expect(processes.last?.pid == 2000)
    }

    /// Each way of not getting a list is "unavailable" (nil), never "no
    /// processes" (empty).
    @Test func unreadableProcessListIsUnavailableNotEmpty() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        // Doesn't launch — what /usr/bin/ps, which macOS doesn't have, did.
        #expect(AgentScanner.liveProcesses(executable: dir.appendingPathComponent("missing"), limits: fast) == nil)
        // Fails, even after printing rows.
        #expect(AgentScanner.liveProcesses(executable: try fakePS("echo '1 /sbin/launchd'; exit 1", in: dir), limits: fast) == nil)
        // Never finishes.
        #expect(AgentScanner.liveProcesses(executable: try fakePS("exec sleep 30", in: dir), limits: fast) == nil)
        // Writes more than the cap.
        var small = fast
        small.outputLimit = 1024
        let flood = try fakePS("i=1; while [ $i -le 400 ]; do echo \"$i /usr/local/bin/tool\"; i=$((i+1)); done", in: dir)
        #expect(AgentScanner.liveProcesses(executable: flood, limits: small) == nil)
        // Succeeds but lists nothing: a real ps always lists itself.
        #expect(AgentScanner.liveProcesses(executable: try fakePS("exit 0", in: dir), limits: fast) == nil)
    }

    /// With the list unavailable a growing transcript is live on its own
    /// evidence — not a zombie — and nothing claims to know what's running.
    @Test func scanWithoutAProcessListDoesNotCallSessionsZombies() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active.jsonl")
        let quiet = root.appendingPathComponent("quiet.jsonl")
        try usageLine(120).write(to: active)
        try usageLine(3600).write(to: quiet)
        let scanner = AgentScanner(providers: [GenericProvider()], roots: [(.other, root.path)], processList: { nil })
        func health(_ result: AgentScanResult, _ file: URL) -> SessionHealth? {
            result.snapshot.sessions.first { $0.filePath == file.path }?.health
        }

        var result = scanner.scan(now: now)
        #expect(!result.snapshot.processListAvailable)
        #expect(result.snapshot.processCounts.isEmpty)
        // Nothing has been seen growing yet.
        #expect(health(result, active) == .ended)

        try append(active, usageLine(30))
        try append(quiet, usageLine(3000))
        result = scanner.scan(now: now, previousSessions: result.sessions, offsets: result.offsets, identities: result.identities)
        #expect(health(result, active) == .live)
        #expect(result.snapshot.sessions.allSatisfy { $0.pid == nil && $0.footprint == nil })
        // Grew, but its newest event is 50 minutes old: not live, and still
        // not a zombie.
        #expect(health(result, quiet) == .ended)
        #expect(result.snapshot.attentionCount == 0)
        #expect(result.snapshot.runningSummary.processes == 1)
        #expect(result.snapshot.runningSummary.measured == 0)

        // Between writes it stays live while the last event is recent…
        result = scanner.scan(now: now, previousSessions: result.sessions, offsets: result.offsets, identities: result.identities)
        #expect(health(result, active) == .live)
        // …and ends once it has been quiet for ten minutes.
        result = scanner.scan(now: now.addingTimeInterval(900), previousSessions: result.sessions,
                              offsets: result.offsets, identities: result.identities)
        #expect(health(result, active) == .ended)
    }

    /// The contrast: a list that was read and holds no agent process does
    /// make a growing transcript a zombie.
    @Test func scanWithAnEmptyProcessListStillFlagsZombies() throws {
        let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("active.jsonl")
        try usageLine(120).write(to: file)
        let scanner = AgentScanner(providers: [GenericProvider()], roots: [(.other, root.path)],
                                   processList: { [AgentProcess(pid: 1, args: "/sbin/launchd")] })
        var result = scanner.scan(now: now)
        try append(file, usageLine(30))
        result = scanner.scan(now: now, previousSessions: result.sessions, offsets: result.offsets, identities: result.identities)
        #expect(result.snapshot.processListAvailable)
        #expect(result.snapshot.sessions.first?.health == .zombie)
    }
}
