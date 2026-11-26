import Foundation

/// A coding-agent product family. `other` covers anything detected by the
/// generic JSONL fallback that has no dedicated adapter yet.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, openclaw, devin, gemini, aider, goose, opencode, cursor, windsurf, amp, continue_, copilot, other
    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .openclaw: return "OpenClaw"
        case .devin: return "Devin"
        case .gemini: return "Gemini"
        case .aider: return "Aider"
        case .goose: return "Goose"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .amp: return "Amp"
        case .continue_: return "Continue"
        case .copilot: return "Copilot"
        case .other: return "Agent"
        }
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public init() {}
    public var total: Int64 { input + output + cacheRead + cacheWrite }
    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input; lhs.output += rhs.output; lhs.cacheRead += rhs.cacheRead; lhs.cacheWrite += rhs.cacheWrite
    }
    /// Field by field, how far `self` is above `other`; never negative.
    public func excess(over other: TokenUsage) -> TokenUsage {
        var delta = TokenUsage()
        delta.input = max(0, input - other.input)
        delta.output = max(0, output - other.output)
        delta.cacheRead = max(0, cacheRead - other.cacheRead)
        delta.cacheWrite = max(0, cacheWrite - other.cacheWrite)
        return delta
    }
}

/// Cross-agent tool grouping so "Bash" / "exec_command" / "run_terminal"
/// compare as the same thing. Raw names are kept for display.
public enum ToolCategory: String, Codable, Sendable {
    case shell, edit, read, search, network, message, mcp, think, other
    public var title: String {
        switch self {
        case .shell: return "Shell"
        case .edit: return "Edits"
        case .read: return "Reads"
        case .search: return "Search"
        case .network: return "Network"
        case .message: return "Messages"
        case .mcp: return "MCP"
        case .think: return "Reasoning"
        case .other: return "Other"
        }
    }
}

public enum ToolTaxonomy {
    public static func categorize(_ raw: String) -> ToolCategory {
        let name = raw.lowercased()
        if name.hasPrefix("mcp__") { return .mcp }
        switch name {
        case let n where n.contains("bash") || n.contains("shell") || n.contains("exec") || n.contains("terminal") || n.contains("run_command") || n.contains("cmd"): return .shell
        case let n where n.contains("edit") || n.contains("write") || n.contains("patch") || n.contains("apply") || n.contains("create_file"): return .edit
        case let n where n.contains("read") || n.contains("view") || n.contains("cat") || n.contains("grep") || n.contains("list"): return .read
        case let n where n.contains("search") || n.contains("find") || n.contains("glob") || n.contains("lookup") || n.contains("query"): return .search
        case let n where n.contains("fetch") || n.contains("http") || n.contains("web") || n.contains("browse") || n.contains("curl"): return .network
        case let n where n.contains("message") || n.contains("send_") || n.contains("followup") || n.contains("task") || n.contains("delegate"): return .message
        case let n where n.contains("think") || n.contains("reason") || n.contains("plan"): return .think
        default: return .other
        }
    }
}

public enum SessionHealth: String, Codable, Sendable {
    /// Transcript file growing and a matching process is alive.
    case live
    /// Process alive but transcript quiet for >10 min.
    case stuck
    /// Transcript grew but no owning process found.
    case zombie
    /// Session file ended normally (no live process expected).
    case ended
    public var title: String { rawValue.capitalized }
}

/// One agent session, normalized across providers.
public struct AgentSession: Identifiable, Codable, Sendable {
    public var id: String { "\(kind.rawValue):\(sessionId)" }
    public var kind: AgentKind
    public var sessionId: String
    public var projectDir: String
    public var pid: Int32?
    public var startedAt: Date?
    public var lastEventAt: Date?
    public var filePath: String
    public var models = Set<String>()
    public var tokens = TokenUsage()
    /// Raw tool name -> count.
    public var tools: [String: Int] = [:]
    public var costUSD: Double?
    public var unpricedTokens: Int64 = 0
    public var health: SessionHealth = .ended
    /// Live physical footprint of the session's process tree, filled by the
    /// monitor while the Agents card is visible. Not persisted.
    public var footprint: UInt64?
    /// True when some process in that tree couldn't be read, so `footprint`
    /// is a lower bound. Not persisted.
    public var footprintPartial = false
    public init(kind: AgentKind, sessionId: String, projectDir: String, filePath: String) {
        self.kind = kind; self.sessionId = sessionId; self.projectDir = projectDir; self.filePath = filePath
    }
    public var toolTotal: Int { tools.values.reduce(0, +) }
}

/// Hourly token/cost burn attributed to an agent family. Buckets are
/// truncated to the hour; kinds absent simply don't appear.
public struct HourBurn: Identifiable, Sendable, Equatable {
    public var id: Date { hour }
    public var hour: Date
    public var tokens: [AgentKind: Int64] = [:]
    public var cost: [AgentKind: Double] = [:]
    public init(hour: Date) { self.hour = hour }
}

/// A detected agent installation root (may or may not have sessions).
public struct AgentRoot: Identifiable, Sendable {
    public var id: String { kind.rawValue + path }
    public var kind: AgentKind
    public var path: String
    public var exists: Bool
    public var sessionFiles: Int
    public init(kind: AgentKind, path: String, exists: Bool, sessionFiles: Int = 0) {
        self.kind = kind; self.path = path; self.exists = exists; self.sessionFiles = sessionFiles
    }
}

/// Everything the UI needs; produced by AgentScanner, published by the monitor.
public struct AgentSnapshot: Sendable {
    public var sessions: [AgentSession] = []
    public var roots: [AgentRoot] = []
    /// Tokens whose own event time falls in the local calendar day, summed
    /// from hourly burn (see `setToday`), not from session lifetime totals.
    public var todayTokens: Int64 = 0
    /// Sum over priced models only; nil when nothing today could be priced.
    public var todayCostUSD: Double?
    /// A lower bound on today's tokens that `todayCostUSD` leaves out: hourly
    /// burn keeps tokens and cost per agent kind, not per model, so only an
    /// hour in which a kind had no priced usage at all is known to be unpriced.
    public var unpricedTokensToday: Int64 = 0
    public var scannedAt: Date?
    /// Agent processes `ps` showed per kind at scan time. Empty when unknown
    /// (fixtures, previews, an unreadable process list); `runningSummary`
    /// then can't bound pid-less rows.
    public var processCounts: [AgentKind: Int] = [:]
    /// False when the scan couldn't read the process list. Sessions then
    /// carry no pid and no footprint, health comes from transcript activity
    /// alone, and "nothing running" isn't a claim the snapshot can make.
    public var processListAvailable = true
    public init() {}
    public var live: [AgentSession] { sessions.filter { $0.health == .live || $0.health == .stuck } }
    /// Running agent processes and their summed footprint, counted per
    /// distinct process: sessions sharing a pid count once, and live sessions
    /// without a pid count only as far as that kind has processes no other
    /// running session already holds. `measured` is how many of `processes`
    /// have a footprint in `footprint`; fewer means the sum is a lower bound.
    public var runningSummary: (processes: Int, footprint: UInt64, measured: Int) {
        let running = live
        var pids: Set<Int32> = []
        var footprints: [Int32: UInt64] = [:]
        var pidsByKind: [AgentKind: Set<Int32>] = [:]
        var pidless: [AgentKind: Int] = [:]
        for session in running {
            if let pid = session.pid {
                pids.insert(pid)
                pidsByKind[session.kind, default: []].insert(pid)
                if let footprint = session.footprint { footprints[pid] = footprint }
            } else {
                pidless[session.kind, default: 0] += 1
            }
        }
        var processes = pids.count
        for (kind, count) in pidless {
            let free = processCounts[kind].map { max(0, $0 - (pidsByKind[kind]?.count ?? 0)) } ?? count
            processes += min(count, free)
        }
        return (processes, footprints.values.reduce(0, +), footprints.count)
    }
    public var attentionCount: Int { sessions.filter { $0.health == .stuck || $0.health == .zombie }.count }
    public var byKindToday: [AgentKind: Int] {
        var counts: [AgentKind: Int] = [:]
        for s in sessions where Calendar.current.isDateInToday(s.lastEventAt ?? .distantPast) {
            counts[s.kind, default: 0] += 1
        }
        return counts
    }

    /// Sets today's totals from hourly burn: every bucket that starts within
    /// `now`'s local calendar day. Buckets are epoch-hour aligned, so in a
    /// time zone offset by 30 or 45 minutes the hour straddling midnight
    /// belongs to yesterday and the first part-hour of the day isn't counted
    /// until the next bucket. Buckets sharing an hour are summed first.
    mutating func setToday(from burn: [HourBurn], now: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        var hours: [Date: HourBurn] = [:]
        for bucket in burn where bucket.hour >= start && bucket.hour < end {
            var merged = hours[bucket.hour] ?? HourBurn(hour: bucket.hour)
            for (kind, tokens) in bucket.tokens { merged.tokens[kind, default: 0] += tokens }
            for (kind, cost) in bucket.cost { merged.cost[kind, default: 0] += cost }
            hours[bucket.hour] = merged
        }
        var tokens: Int64 = 0, unpriced: Int64 = 0, cost = 0.0
        for bucket in hours.values {
            cost += bucket.cost.values.reduce(0, +)
            for (kind, count) in bucket.tokens where count > 0 {
                tokens += count
                if (bucket.cost[kind] ?? 0) <= 0 { unpriced += count }
            }
        }
        todayTokens = tokens
        todayCostUSD = cost > 0 ? cost : nil
        unpricedTokensToday = unpriced
    }
}

public struct PriceRate: Sendable {
    public var input, output, cacheRead, cacheWrite: Double // per million tokens
}

/// Versioned price table. Unknown models return nil and land in `unpriced`
/// buckets — cost is always honest about what it couldn't price.
public enum AgentPricing {
    /// The Opus rate is the list price from Opus 4.5 on. Opus 4 and 4.1
    /// (`claude-opus-4`, `claude-opus-4-0`, `claude-opus-4-1…` and the dated
    /// `claude-opus-4-2025…` ids) were priced differently, so they are left
    /// out and count as unpriced rather than being estimated at this rate.
    private static let table: [(pattern: String, rate: PriceRate)] =
        ["5", "6", "7", "8", "9"].map {
            ("claude-opus-4-\($0)", PriceRate(input: 5.0, output: 25.0, cacheRead: 0.50, cacheWrite: 6.25))
        } + [
            ("claude-sonnet-4", .init(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)),
            ("claude-haiku-4", .init(input: 1.0, output: 5.0, cacheRead: 0.10, cacheWrite: 1.25)),
        ]
    /// Family-prefix match. Returns nil when we don't know the price.
    public static func rate(for model: String) -> PriceRate? {
        let m = model.lowercased()
        for (pattern, rate) in table where m.hasPrefix(pattern) { return rate }
        return nil
    }
    public static func cost(_ usage: TokenUsage, model: String) -> Double? {
        guard let r = rate(for: model) else { return nil }
        return (Double(usage.input) * r.input + Double(usage.output) * r.output
              + Double(usage.cacheRead) * r.cacheRead + Double(usage.cacheWrite) * r.cacheWrite) / 1_000_000
    }
}

/// What one transcript line contributed when a provider folded it into a
/// session: the event's own timestamp, the tokens it added, and the model
/// they were attributed to when the line names one. The scanner buckets
/// these into `HourBurn` so burn is counted exactly once per parsed line —
/// pricing stays centralized in the scanner via `AgentPricing`.
public struct AgentLineEvent: Sendable {
    /// The line's own timestamp; nil when the transcript didn't carry one.
    public var at: Date?
    /// Tokens this line added to the session (zero for non-usage lines).
    public var tokens = TokenUsage()
    /// The model this line's tokens belong to, when directly attributable.
    public var model: String?
    /// Input, not output: the scanner sets it before `parse` to the byte
    /// offset of the line in its file, so a provider that de-duplicates can
    /// tell the same line being read again (a retried scan) from a second
    /// copy of the message elsewhere. Nil when a line is parsed on its own.
    public var lineOffset: Int64?
    public init() {}
}

/// A provider discovers session files for one agent family and normalizes
/// transcript lines into session state. Implementations must be cheap:
/// files are read tail-only (offset-resume) and never in full twice.
public protocol AgentProvider {
    var kind: AgentKind { get }
    /// Artifact roots this provider watches (e.g. ~/.claude).
    var roots: [String] { get }
    /// Candidate transcript/session files under the roots.
    func sessionFiles() -> [URL]
    /// The directory trees `sessionFiles()` walks, declared so the scanner
    /// can discover them through its listing cache instead of calling
    /// `sessionFiles()` every scan. Empty: the scanner falls back to
    /// `sessionFiles()`, refreshed whenever a watched directory changes.
    var sessionTrees: [AgentSessionTree] { get }
    /// Fold one JSONL line into session state, reporting the line's own
    /// contribution into `event` for hourly burn accounting. Returns false
    /// for ignorable lines.
    func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool
}

/// `.jsonl` files `minDepth...depth` levels below `path`, optionally
/// filtered by file-name prefix (same hidden-file rules as the root walk).
public struct AgentSessionTree: Sendable {
    public var path: String
    public var depth: Int
    public var minDepth: Int
    public var namePrefix: String?
    public init(path: String, depth: Int, minDepth: Int = 1, namePrefix: String? = nil) {
        self.path = path; self.depth = depth; self.minDepth = minDepth; self.namePrefix = namePrefix
    }
}

public extension AgentProvider {
    var sessionTrees: [AgentSessionTree] { [] }

    /// Convenience for callers that don't need per-line accounting.
    func parse(line: Data, into session: inout AgentSession) -> Bool {
        var event = AgentLineEvent()
        return parse(line: line, into: &session, event: &event)
    }
}
