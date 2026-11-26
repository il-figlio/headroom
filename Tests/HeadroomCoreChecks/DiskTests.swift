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
        // Free space drops 2 GB/hour across three hours: 48 GB/day, ~0.2 days left at 10 GB.
        for i in 0...3 {
            _ = try store.record(memory: memory(), apps: [], disk: disk(free: UInt64(16 << 30) - UInt64(i) * (2 << 30)), at: base.addingTimeInterval(Double(i) * 3600))
        }
        let summary = try store.summary(now: base.addingTimeInterval(3 * 3600))
        #expect(abs((summary.diskRateGBPerDay ?? 0) - 48) < 2)
        #expect(abs((summary.daysUntilFull ?? 0) - 10.0 / 48.0) < 0.1)
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
}
