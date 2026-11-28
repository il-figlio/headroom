import Foundation
import Testing
@testable import HeadroomCore

/// Builds up to 0.8.0 kept data in Application Support/Headroom, a folder an
/// unrelated app with the same name also uses. Only this app's files move, and
/// only when the folder is ours and nothing is in the new place yet.
@Suite struct LegacyDirectoryChecks {
    func scratch() throws -> (legacy: URL, current: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base.appendingPathComponent("Headroom"), base.appendingPathComponent("org.headroom.app"))
    }
    func write(_ text: String, _ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }
    func exists(_ url: URL, _ name: String = "") -> Bool {
        FileManager.default.fileExists(atPath: (name.isEmpty ? url : url.appendingPathComponent(name)).path)
    }

    @Test func movesOurFilesAndRemovesEmptyFolder() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations\n\nUpdated now.", "log.md", in: legacy)
        for name in ["history.sqlite", "history.sqlite-wal", "quota-cache.json"] { try write("x", name, in: legacy) }
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        for name in ["log.md", "history.sqlite", "history.sqlite-wal", "quota-cache.json"] { #expect(exists(current, name)) }
        #expect(!exists(legacy))
    }

    @Test func leavesDevelopmentSigningBehind() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try write("db", "history.sqlite", in: legacy)
        try write("keychain", "signing/headroom-signing.keychain-db", in: legacy)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        #expect(exists(current, "history.sqlite"))
        #expect(exists(legacy, "signing/headroom-signing.keychain-db"))
        #expect(!exists(legacy, "history.sqlite"))
    }

    @Test func leavesAnotherAppsFolder() throws {
        let (legacy, current) = try scratch()
        try write("db", "history.sqlite", in: legacy)
        try write("something else", "log.md", in: legacy)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .notNeeded)
        #expect(exists(legacy, "history.sqlite"))
        #expect(!exists(current))
    }

    @Test func neverOverwritesExistingHistory() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try write("old", "history.sqlite", in: legacy)
        try write("new", "history.sqlite", in: current)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .notNeeded)
        #expect(exists(legacy, "history.sqlite"))
        #expect(try String(contentsOf: current.appendingPathComponent("history.sqlite"), encoding: .utf8) == "new")
    }

    @Test func movesIntoAnEmptyNewFolder() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        #expect(exists(current, "log.md"))
    }

    @Test func nothingToMove() throws {
        let (legacy, current) = try scratch()
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .notNeeded)
        #expect(!exists(current))
    }

    // MARK: A real database, archives, and interrupted moves

    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let marker = HistoryStore.migrationMarker
    let archive = "Archives/1790000000-A1B2C3"

    func size(_ url: URL, _ name: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path))?[.size] as? Int) ?? -1
    }
    func text(_ url: URL, _ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }
    /// Opens the history in `dir` and counts its samples.
    func samples(in dir: URL) throws -> String {
        try HistoryStore(directory: dir, now: base).executeForTesting("SELECT count(*) FROM samples")[0][0]
    }
    /// Fills `legacy` the way a build up to 0.8.0 leaves it when it quits: the
    /// app never closes the database, so the newest rows are still in the -wal.
    /// The files are copied while the writing store is open, as a kill would
    /// leave them. Also adds a quota cache and one kept archive.
    func legacyInstall(_ legacy: URL, rows: Int = 5) throws {
        let live = legacy.deletingLastPathComponent().appendingPathComponent("live")
        let store = try HistoryStore(directory: live, now: base)
        let memory = SystemMemory(total: 16 << 30, used: 10 << 30, compressed: 2 << 30, swap: 0, pressure: .normal, valid: true)
        for i in 0..<rows { try store.record(memory: memory, apps: [], at: base.addingTimeInterval(Double(i) * 60)) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "log.md"] {
            try FileManager.default.copyItem(at: live.appendingPathComponent(name), to: legacy.appendingPathComponent(name))
        }
        try write("{}", "quota-cache.json", in: legacy)
        try write("archived database", archive + "/history.sqlite", in: legacy)
        try write("# Headroom observations\n\nArchived.", archive + "/log.md", in: legacy)
        withExtendedLifetime(store) {}
    }
    /// Everything of ours is in the new folder and nothing is left of the old one.
    func expectFullyMoved(_ legacy: URL, _ current: URL, rows: String = "5", _ note: Comment? = nil) throws {
        #expect(try samples(in: current) == rows, note)
        #expect(text(current, "log.md")?.hasPrefix("# Headroom observations") == true, note)
        #expect(text(current, "quota-cache.json") == "{}", note)
        #expect(text(current, archive + "/history.sqlite") == "archived database", note)
        #expect(text(current, archive + "/log.md")?.hasSuffix("Archived.") == true, note)
        #expect(!exists(current, marker), note)
        #expect(!exists(legacy), note)
    }

    @Test func movesADatabaseWhoseNewestRowsAreOnlyInTheWriteAheadLog() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try legacyInstall(legacy)
        // The fixture is what it claims: the rows are in the -wal, not the main file.
        #expect(size(legacy, "history.sqlite-wal") > 0)
        let alone = legacy.deletingLastPathComponent().appendingPathComponent("alone")
        try FileManager.default.createDirectory(at: alone, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: legacy.appendingPathComponent("history.sqlite"), to: alone.appendingPathComponent("history.sqlite"))
        #expect(try samples(in: alone) == "0")

        #expect(HistoryStore.legacyMigrationPending(from: legacy, to: current))
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        #expect(!HistoryStore.legacyMigrationPending(from: legacy, to: current))
        // Folded in before the move, so the main file holds the rows by itself.
        #expect(size(current, "history.sqlite-wal") <= 0)
        try expectFullyMoved(legacy, current)
        // A second launch has nothing to do.
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .notNeeded)
    }

    /// Stops the move after every possible number of steps, as a kill or power
    /// loss would, then lets the next launch run it. The outcome is always the
    /// complete move.
    @Test func resumesFromEveryInterruptionPoint() throws {
        var interrupted = 0
        var completedFirstTime = false
        for steps in 0...12 {
            let (legacy, current) = try scratch()
            defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
            try legacyInstall(legacy)
            let outcome = HistoryStore.migrateLegacyDirectory(from: legacy, to: current, stoppingAfter: steps)
            if exists(legacy) || exists(current, marker) {
                #expect(outcome == .blocked)
                interrupted += 1
                // Nothing is ever in both places or in neither.
                for name in ["history.sqlite", "log.md", "quota-cache.json", archive + "/history.sqlite"] {
                    #expect(exists(legacy, name) != exists(current, name), "\(name) after \(steps) steps")
                }
            } else {
                #expect(outcome == .completed)
                completedFirstTime = true
            }
            HistoryStore.migrateLegacyDirectory(from: legacy, to: current)
            try expectFullyMoved(legacy, current, "after \(steps) steps")
        }
        #expect(interrupted >= 7)
        #expect(completedFirstTime)
    }

    /// The state the first rename used to leave for good: database in the new
    /// folder, its -wal (with the rows) still in the old one.
    @Test func resumeBringsTheWriteAheadLogToItsDatabase() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try legacyInstall(legacy)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: legacy.appendingPathComponent("history.sqlite"), to: current.appendingPathComponent("history.sqlite"))
        try write("moving", marker, in: current)
        #expect(HistoryStore.legacyMigrationPending(from: legacy, to: current))
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        try expectFullyMoved(legacy, current)
    }

    /// Without the marker, history in the new folder means the move is over.
    @Test func databaseInTheNewFolderWithoutAMarkerIsNotAnInterruptedMove() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try legacyInstall(legacy)
        try write("new", "history.sqlite", in: current)
        #expect(!HistoryStore.legacyMigrationPending(from: legacy, to: current))
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .notNeeded)
        for name in ["history.sqlite-wal", "quota-cache.json", "log.md", archive + "/log.md"] { #expect(exists(legacy, name)) }
        #expect(!exists(current, "Archives"))
    }

    @Test func resumeNeverReplacesWhatTheNewFolderHas() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try legacyInstall(legacy)
        try write("moving", marker, in: current)
        try write("new", "history.sqlite", in: current)
        try write("# Headroom observations\n\nNew.", "log.md", in: current)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .blocked)
        #expect(text(current, "history.sqlite") == "new")
        #expect(text(current, "log.md")?.hasSuffix("New.") == true)
        // The old database stays whole where it was, sidecars included.
        for name in ["history.sqlite", "history.sqlite-wal", "log.md"] { #expect(exists(legacy, name)) }
        #expect(!exists(current, "history.sqlite-wal"))
        #expect(exists(current, marker))
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .blocked)
    }

    @Test func mergesArchivesIntoAnExistingArchivesFolder() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try legacyInstall(legacy)
        try write("older archive", "Archives/1780000000-FFFFFF/history.sqlite", in: legacy)
        // The new folder already has an archive of its own and one with the same name.
        try write("kept", "Archives/1795000000-ABCDEF/history.sqlite", in: current)
        try write("already here", archive + "/history.sqlite", in: current)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        #expect(text(current, "Archives/1795000000-ABCDEF/history.sqlite") == "kept")
        #expect(text(current, "Archives/1780000000-FFFFFF/history.sqlite") == "older archive")
        // Same name on both sides: neither is touched, so the old folder stays for it.
        #expect(text(current, archive + "/history.sqlite") == "already here")
        #expect(!exists(current, archive + "/log.md"))
        #expect(text(legacy, archive + "/history.sqlite") == "archived database")
        #expect(try FileManager.default.contentsOfDirectory(atPath: legacy.path) == ["Archives"])
        #expect(try samples(in: current) == "5")
        #expect(!exists(current, marker))
    }

    /// A database another connection is reading belongs to a copy that is
    /// still running. Nothing moves until it lets go.
    @Test func leavesABusyDatabaseForALaterLaunch() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try legacyInstall(legacy)
        do {
            let running = try HistoryStore(directory: legacy, now: base)
            try running.executeForTesting("BEGIN")
            #expect(try running.executeForTesting("SELECT count(*) FROM samples")[0][0] == "5")
            #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .blocked)
            for name in ["history.sqlite", "quota-cache.json", "log.md", archive + "/log.md"] { #expect(exists(legacy, name)) }
            #expect(!exists(current, "history.sqlite"))
            #expect(HistoryStore.legacyMigrationPending(from: legacy, to: current))
            try running.executeForTesting("ROLLBACK")
        }
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .completed)
        try expectFullyMoved(legacy, current)
    }

    @Test func checkpointErrorKeepsDatabaseAndMarkerForRetry() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try write("# Headroom observations", "log.md", in: legacy)
        let corrupt = "SQLite format 3\0" + String(repeating: "x", count: 200)
        try write(corrupt, "history.sqlite", in: legacy)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .blocked)
        #expect(text(legacy, "history.sqlite") == corrupt)
        #expect(exists(current, marker))
        #expect(!exists(current, "history.sqlite"))
    }

    /// A marker doesn't make someone else's folder ours.
    @Test func markerWithAnotherAppsFolderMovesNothing() throws {
        let (legacy, current) = try scratch()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        try write("something else", "log.md", in: legacy)
        try write("db", "history.sqlite", in: legacy)
        try write("theirs", "Archives/one/file", in: legacy)
        try write("moving", marker, in: current)
        #expect(!HistoryStore.legacyMigrationPending(from: legacy, to: current))
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current) == .notNeeded)
        for name in ["log.md", "history.sqlite", "Archives/one/file"] { #expect(exists(legacy, name)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: current.path).isEmpty)
    }

    /// What Settings and the History window show while the move is blocked.
    @Test func blockedMoveExplainsItselfWithBothFolders() {
        let message = HistoryStore.MoveBlocked().localizedDescription
        #expect(message.contains("~/Library/Application Support/Headroom to ~/Library/Application Support/org.headroom.app"))
        #expect(message.contains("Quit any other copies of Headroom"))
        #expect(message.contains("then open Headroom again."))
        #expect(!message.contains(NSHomeDirectory()))
    }

    @Test func aRunningCopyDecidesWhetherThisLaunchMoves() {
        var asked = 0
        func pending(_ value: Bool) -> Bool { asked += 1; return value }
        // Alone (or not in a bundle at all): move, without needing to look first.
        #expect(HistoryStore.legacyMigrationDecision(ownPID: 10, runningPIDs: [], pending: pending(true)) == .migrate)
        #expect(HistoryStore.legacyMigrationDecision(ownPID: 10, runningPIDs: [10], pending: pending(false)) == .migrate)
        #expect(asked == 0)
        // Another copy has the legacy data: hands off both folders.
        #expect(HistoryStore.legacyMigrationDecision(ownPID: 10, runningPIDs: [10, 11], pending: pending(true)) == .wait)
        #expect(HistoryStore.legacyMigrationDecision(ownPID: 10, runningPIDs: [11], pending: pending(true)) == .wait)
        // Another copy is running and there is nothing left to move.
        #expect(HistoryStore.legacyMigrationDecision(ownPID: 10, runningPIDs: [11], pending: pending(false)) == .proceed)
        #expect(asked == 3)
    }
}
