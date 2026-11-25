import Foundation
import Testing
@testable import HeadboardCore

/// The pre-rename folder ("Headroom") is shared by name with an unrelated app,
/// so it moves only when it is ours and only if nothing is at the new path yet.
@Suite struct LegacyDirectoryChecks {
    func scratch() throws -> (legacy: URL, current: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("headboard-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base.appendingPathComponent("Headroom"), base.appendingPathComponent("Headboard"))
    }
    func write(_ text: String, _ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    @Test func movesOurFolder() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations\n\nUpdated now.", "log.md", in: legacy)
        try write("db", "history.sqlite", in: legacy)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("history.sqlite").path))
    }

    @Test func leavesAnotherAppsFolder() throws {
        let (legacy, current) = try scratch()
        try write("db", "history.sqlite", in: legacy)
        try write("something else", "log.md", in: legacy)
        #expect(!HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("history.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    @Test func neverOverwritesNewFolder() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try write("# Headboard observations", "log.md", in: current)
        #expect(!HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func nothingToMove() throws {
        let (legacy, current) = try scratch()
        #expect(!HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
    }
}
