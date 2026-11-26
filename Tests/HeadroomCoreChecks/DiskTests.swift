import Foundation
import Testing
import CSQLite
@testable import HeadroomCore

@Suite struct DiskTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func memory() -> SystemMemory {
        .init(total: 16 << 30, used: 10 << 30, compressed: 2 << 30, swap: 0, pressure: .normal, valid: true)
    }
    func disk(free: UInt64, total: UInt64 = 228 << 30, purgeable: UInt64 = 0) -> DiskSpace {
        .init(total: total, free: free, purgeable: purgeable, valid: true)
    }
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)")
    }
    /// One reading every ten minutes from `hours.lowerBound` to `hours.upperBound`.
    func record(_ store: HistoryStore, hours: ClosedRange<Double>, free: (Double) -> Double) throws {
        for step in Int(hours.lowerBound * 6)...Int(hours.upperBound * 6) {
            let hour = Double(step) / 6
            _ = try store.record(memory: memory(), apps: [], disk: disk(free: UInt64(free(hour) * 1_073_741_824)),
                                 at: base.addingTimeInterval(hour * 3600))
        }
    }

    @Test func liveDiskRead() {
        let disk = DiskSpace.read()
        #expect(disk.valid)
        #expect(disk.total > 0)
        #expect(disk.free <= disk.total)
        #expect(disk.used + disk.free == disk.total)
    }
    @Test func diskUrgencyThresholds() {
        #expect(disk(free: 2 << 30).urgency == .critical)   // <1% free
        #expect(disk(free: 20 << 30).urgency == .low)       // ~9% free
        #expect(disk(free: 60 << 30).urgency == .ample)     // ~26% free
        #expect(DiskSpace(total: 100, free: 50, purgeable: 0, valid: false).urgency == .ample)
    }
    @Test func recordStoresDiskAndLowSpaceSkipsWrites() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        _ = try store.record(memory: memory(), apps: [], disk: disk(free: 10 << 30), at: base)
        var summary = try store.summary(now: base)
        #expect(summary.latestDiskFree == 10 << 30)
        #expect(summary.latestDiskTotal == 228 << 30)
        // Below the guard threshold, history drops the sample instead of writing.
        _ = try store.record(memory: memory(), apps: [], disk: disk(free: 100_000_000), at: base.addingTimeInterval(60))
        summary = try store.summary(now: base.addingTimeInterval(60))
        #expect(summary.sampleCount == 1)
    }
    @Test func migrationAddsDiskColumnsToLegacyDatabase() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE samples (ts REAL PRIMARY KEY, used REAL, total REAL, compressed REAL, swap REAL, pressure INTEGER, apps TEXT)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO samples VALUES (1800000000, 1, 16, 2, 0, 1, '[]')", nil, nil, nil)
        sqlite3_close(db)
        let store = try HistoryStore(directory: dir, now: base)
        let summary = try store.record(memory: memory(), apps: [], disk: disk(free: 9 << 30), at: base.addingTimeInterval(60))
        #expect(summary.sampleCount == 2)
        #expect(summary.latestDiskFree == 9 << 30)
    }
    @Test func diskRateAndDaysUntilFull() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        // Free space drops 2 GB/hour across eight hours: 48 GB/day, ~0.2 days left at 10 GB.
        try record(store, hours: 0...8) { 26 - 2 * $0 }
        let summary = try store.summary(now: base.addingTimeInterval(8 * 3600))
        #expect(abs((summary.diskRateGBPerDay ?? 0) - 48) < 0.5)
        #expect(abs((summary.daysUntilFull ?? 0) - 10.0 / 48.0) < 0.01)
        #expect(summary.recommendations.contains { $0.title == "Disk is filling quickly" })
    }
    /// A 10 GB download in the first hour of history used to read as about
    /// 240 GB/day. No rate is reported until readings span six hours.
    @Test func diskRateWaitsForSixHoursOfReadings() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        try record(store, hours: 0...1) { 100 - 10 * $0 }
        var summary = try store.summary(now: base.addingTimeInterval(3600))
        #expect(summary.diskRateGBPerDay == nil)
        #expect(summary.daysUntilFull == nil)
        #expect(!summary.recommendations.contains { $0.title == "Disk is filling quickly" })
        // Flat afterwards, up to just short of six hours: still nothing.
        try record(store, hours: 1.5...5.5) { _ in 90 }
        summary = try store.summary(now: base.addingTimeInterval(5.5 * 3600))
        #expect(summary.diskRateGBPerDay == nil)
        #expect(summary.daysUntilFull == nil)
        // At six hours a rate appears.
        try record(store, hours: 6...6) { _ in 90 }
        summary = try store.summary(now: base.addingTimeInterval(6 * 3600))
        #expect(summary.diskRateGBPerDay != nil)
    }
    /// The same download followed by a quiet day: the two-endpoint rate stays at
    /// the full 10 GB/day until the hour leaves the window, while the fitted line
    /// sees a day of flat readings.
    @Test func diskRateFitsEveryReadingNotJustTheEndpoints() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        try record(store, hours: 0...1) { 100 - 10 * $0 }
        try record(store, hours: 1.5...23.5) { _ in 90 }
        let summary = try store.summary(now: base.addingTimeInterval(23.5 * 3600))
        let rate = try #require(summary.diskRateGBPerDay)
        #expect(rate > 0 && rate < 3)
        #expect(!summary.recommendations.contains { $0.title == "Disk is filling quickly" })
    }
    @Test func diskRateIsNegativeWhenSpaceIsFreed() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        try record(store, hours: 0...7) { 50 + $0 }
        var summary = try store.summary(now: base.addingTimeInterval(7 * 3600))
        #expect(abs((summary.diskRateGBPerDay ?? 0) + 24) < 0.5)
        #expect(summary.daysUntilFull == nil)
        // Unchanged readings are a rate of exactly zero, not a tiny slope.
        let flatDir = directory(); defer { try? FileManager.default.removeItem(at: flatDir) }
        let flat = try HistoryStore(directory: flatDir, now: base)
        try record(flat, hours: 0...7) { _ in 50 }
        summary = try flat.summary(now: base.addingTimeInterval(7 * 3600))
        #expect(summary.diskRateGBPerDay == 0)
        #expect(summary.daysUntilFull == nil)
    }
    @Test func consumerRoundTripKeepsPreviousScan() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        try store.saveConsumers([.init(path: "/a", name: "~/a", bytes: 5 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 0, at: base)
        var scan = try store.loadConsumers()
        #expect(scan.items.first?.bytes == 5 << 30)
        #expect(scan.items.first?.previousBytes == nil)
        try store.saveConsumers([.init(path: "/a", name: "~/a", bytes: 6 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 2, at: base.addingTimeInterval(3600))
        scan = try store.loadConsumers()
        #expect(scan.items.first?.bytes == 6 << 30)
        #expect(scan.items.first?.previousBytes == 5 << 30)
        #expect(scan.items.first?.delta == Int64(1 << 30))
        #expect(scan.localSnapshots == 2)
        // Locations absent from a new scan disappear.
        try store.saveConsumers([], localSnapshots: 0, at: base.addingTimeInterval(7200))
        #expect(try store.loadConsumers().items.isEmpty)
    }
    @Test func diskAdviceFiresOnLowSpaceAndConsumerGrowth() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir, now: base)
        _ = try store.record(memory: memory(), apps: [], disk: disk(free: 8 << 30), at: base)
        try store.saveConsumers([.init(path: "/x", name: "~/x", bytes: 10 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 0, at: base)
        try store.saveConsumers([.init(path: "/x", name: "~/x", bytes: 12 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 0, at: base.addingTimeInterval(3600))
        let titles = try store.summary(now: base).recommendations.map(\.title)
        #expect(titles.contains("Free up disk space soon"))
        #expect(titles.contains { $0.hasPrefix("~/x grew") })
    }
    @Test func scannerSizesDirectoryAndHonorsCancellation() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12345).write(to: dir.appendingPathComponent("blob.bin"))
        let result = ConsumerScanner().scan(roots: [dir])
        #expect(!result.cancelled)
        #expect(abs(Int64(result.consumers.first?.bytes ?? 0) - 12345) <= 8192)
        let cancelled = ConsumerScanner()
        cancelled.cancel()
        #expect(cancelled.scan(roots: [dir]).cancelled)
    }

    // MARK: Time Machine snapshot count

    func tool(_ script: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-tmutil")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    @Test func snapshotCountReadsTheListing() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let listing = try tool(#"[ "$1 $2" = "listlocalsnapshots /" ] || exit 64; echo "Snapshots for disk /:"; echo com.apple.TimeMachine.2026-11-24-101500.local; echo com.apple.TimeMachine.2026-11-25-101500.local; echo com.apple.os.update-ABC"#, in: dir)
        #expect(ConsumerScanner.localSnapshotCount(tool: listing, timeout: 5) == 2)
        #expect(ConsumerScanner.localSnapshotCount(tool: dir.appendingPathComponent("missing"), timeout: 5) == 0)
    }
    /// `tmutil` used to be waited on without limit. A tool that hangs is stopped
    /// and counts as no snapshots.
    @Test func snapshotCountGivesUpOnAToolThatHangs() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let hanging = try tool("echo com.apple.TimeMachine.2026-11-24-101500.local\nexec sleep 30", in: dir)
        let started = Date()
        #expect(ConsumerScanner.localSnapshotCount(tool: hanging, timeout: 0.5) == 0)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
