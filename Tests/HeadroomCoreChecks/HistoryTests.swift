import Foundation
import Testing
@testable import HeadroomCore

@Suite struct HistoryTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func memory(_ pressure: Pressure = .normal, swap: UInt64 = 0) -> SystemMemory {
        .init(total: 16 * 1_073_741_824, used: 10 * 1_073_741_824, compressed: 2 * 1_073_741_824,
              swap: swap, pressure: pressure, valid: true)
    }
    func app(_ bytes: UInt64, session: String = "one", partial: Bool = false, name: String = "Browser") -> ObservedApp {
        .init(key: "com.example.browser", name: name, session: session, bytes: bytes, partial: partial)
    }
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)")
    }
    @Test func observedTimeExcludesSleepAndUnknownPressure() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        _ = try store.record(memory: memory(.warning), apps: [], at: base)
        _ = try store.record(memory: memory(.normal), apps: [], at: base.addingTimeInterval(60))
        _ = try store.record(memory: memory(.unknown), apps: [], at: base.addingTimeInterval(3660))
        let summary = try store.record(memory: memory(), apps: [], at: base.addingTimeInterval(3720))
        #expect(abs(summary.observedMinutes - 1) < 0.001)
        #expect(abs(summary.pressuredMinutes - 1) < 0.001)
    }
    @Test func growthRequiresContinuousSameSessionAndEnoughEvidence() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        for i in 0...20 {
            _ = try store.record(memory: memory(), apps: [app(UInt64(1_073_741_824 + i * 60_000_000))], at: base.addingTimeInterval(Double(i * 60)))
        }
        var summary = try store.summary(now: base.addingTimeInterval(1200))
        #expect(summary.recommendations.contains { $0.title == "Watch Browser's growth" })
        summary = try store.record(memory: memory(), apps: [app(3_500_000_000, session: "restarted")], at: base.addingTimeInterval(1260))
        #expect(!summary.recommendations.contains { $0.title.contains("growth") })
    }
    @Test func partialReadingsAndLongGapsDoNotGenerateGrowthAdvice() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        for i in 0...20 {
            _ = try store.record(memory: memory(), apps: [app(UInt64(1_073_741_824 + i * 60_000_000), partial: true)], at: base.addingTimeInterval(Double(i * 60)))
        }
        var summary = try store.summary(now: base.addingTimeInterval(1200))
        #expect(!summary.recommendations.contains { $0.title.contains("growth") })
        summary = try store.record(memory: memory(), apps: [app(8_000_000_000)], at: base.addingTimeInterval(7200))
        #expect(!summary.recommendations.contains { $0.title.contains("growth") })
    }
    @Test func retentionAndArchivePreserveOldReportAndResetBaseline() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base.addingTimeInterval(-31 * 86400))
        _ = try store.record(memory: memory(), apps: [app(1_000_000_000)], at: base.addingTimeInterval(-31 * 86400))
        _ = try store.record(memory: memory(.warning), apps: [app(2_000_000_000)], at: base)
        #expect(try store.summary(now: base.addingTimeInterval(-31 * 86400)).sampleCount == 0)
        try store.event(kind: "quit-requested", app: "Browser", detail: "Accepted", at: base)
        let report = try String(contentsOf: store.logURL, encoding: .utf8)
        #expect(!report.contains("\(ISO8601DateFormatter().string(from: base.addingTimeInterval(-31 * 86400)))"))
        #expect(report.contains("quit-requested"))
        let archive = try store.archive(at: base)
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("history.sqlite").path))
        #expect(try String(contentsOf: archive.appendingPathComponent("log.md"), encoding: .utf8) == report)
        #expect(try store.summary(now: base).sampleCount == 0)
        #expect(try !String(contentsOf: store.logURL, encoding: .utf8).contains("quit-requested"))
    }
    @Test func reopenPersistsDataAndEscapesAppNames() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try HistoryStore(directory: dir, now: base)
            _ = try store.record(memory: memory(.critical), apps: [app(2_000_000_000, name: "Browser | test\nline")], at: base)
        }
        let store = try HistoryStore(directory: dir, now: base)
        #expect(try store.summary(now: base).sampleCount == 1)
        #expect(try String(contentsOf: store.logURL, encoding: .utf8).contains("Browser \\| test line"))
        #expect(try store.summary(now: base.addingTimeInterval(300)).recommendations.first?.title == "History hasn't updated recently")
    }
    @Test func sustainedPressureAdviceUsesTimeRatherThanSampleCount() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        for i in 0...30 {
            _ = try store.record(memory: memory(.warning, swap: UInt64(i * 30_000_000)), apps: [app(4_000_000_000)], at: base.addingTimeInterval(Double(i * 60)))
        }
        let summary = try store.summary(now: base.addingTimeInterval(1800))
        #expect(abs(summary.observedMinutes - 30) < 0.001)
        #expect(abs(summary.pressuredFraction - 1) < 0.001)
        #expect(summary.recommendations.contains { $0.title == "Reduce the apps running together" })
        #expect(summary.recommendations.contains { $0.title == "Watch the increase in swap" })
    }

    // MARK: Retention when nothing is being recorded

    func counts(_ store: HistoryStore) throws -> [String] {
        try ["samples", "events", "agent_usage"].map { "\($0) \(try store.executeForTesting("SELECT count(*) FROM \($0)")[0][0])" }
    }
    /// Recording paused and Agents off means nothing writes, so nothing used to
    /// prune. Opening the store applies the 30-day limit by itself.
    @Test func openingPrunesRowsOlderThanThirtyDays() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = base.addingTimeInterval(-40 * 86400)
        do {
            let store = try HistoryStore(directory: dir, now: old)
            for (date, pressure) in [(old, Pressure.normal), (old.addingTimeInterval(60), .warning), (base.addingTimeInterval(-3600), .normal), (base, .warning)] {
                _ = try store.record(memory: memory(pressure), apps: [app(1_000_000_000)], at: date)
            }
            // Fixtures go in directly: recordAgentUsage prunes against the real clock.
            for hour in [old, base.addingTimeInterval(-3600)] {
                try store.executeForTesting("INSERT INTO agent_usage VALUES (\(hour.timeIntervalSince1970), 'claude', 10, 0.5)")
            }
            // record() pruned the two old samples when the recent ones arrived; put one back.
            try store.executeForTesting("INSERT INTO samples (ts, used, total, compressed, swap, pressure, apps) VALUES (\(old.timeIntervalSince1970), 1, 16, 2, 0, 1, '[]')")
            try store.executeForTesting("INSERT INTO events (ts, kind, app, detail) VALUES (\(old.timeIntervalSince1970), 'quit-requested', 'Browser', 'Accepted')")
            #expect(try counts(store) == ["samples 3", "events 3", "agent_usage 2"])
        }
        // A day before the old rows expire, opening keeps everything.
        #expect(try counts(HistoryStore(directory: dir, now: old.addingTimeInterval(29 * 86400))) == ["samples 3", "events 3", "agent_usage 2"])
        let store = try HistoryStore(directory: dir, now: base)
        #expect(try counts(store) == ["samples 2", "events 2", "agent_usage 1"])
        // What is left is the recent data, and the summary reads it.
        #expect(try store.executeForTesting("SELECT DISTINCT kind FROM events") == [["pressure-change"]])
        #expect(try store.loadAgentUsage(since: old).map(\.hour) == [base.addingTimeInterval(-3600)])
        let summary = try store.summary(now: base)
        #expect(summary.sampleCount == 2)
        #expect(summary.latestPressure == .warning)
    }
    /// A row exactly thirty days old stays; a second older and it goes.
    @Test func openingAtTheRetentionBoundaryKeepsTheRow() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try HistoryStore(directory: dir, now: base)
            _ = try store.record(memory: memory(), apps: [], at: base)
        }
        let edge = base.addingTimeInterval(HistoryStore.retention)
        #expect(try counts(HistoryStore(directory: dir, now: edge))[0] == "samples 1")
        #expect(try counts(HistoryStore(directory: dir, now: edge.addingTimeInterval(1)))[0] == "samples 0")
    }
}
