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
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        for name in ["log.md", "history.sqlite", "history.sqlite-wal", "quota-cache.json"] { #expect(exists(current, name)) }
        #expect(!exists(legacy))
    }

    @Test func leavesDevelopmentSigningBehind() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try write("db", "history.sqlite", in: legacy)
        try write("keychain", "signing/headroom-signing.keychain-db", in: legacy)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(exists(current, "history.sqlite"))
        #expect(exists(legacy, "signing/headroom-signing.keychain-db"))
        #expect(!exists(legacy, "history.sqlite"))
    }

    @Test func leavesAnotherAppsFolder() throws {
        let (legacy, current) = try scratch()
        try write("db", "history.sqlite", in: legacy)
        try write("something else", "log.md", in: legacy)
        #expect(!HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(exists(legacy, "history.sqlite"))
        #expect(!exists(current))
    }

    @Test func neverOverwritesExistingHistory() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try write("old", "history.sqlite", in: legacy)
        try write("new", "history.sqlite", in: current)
        #expect(!HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(exists(legacy, "history.sqlite"))
        #expect(try String(contentsOf: current.appendingPathComponent("history.sqlite"), encoding: .utf8) == "new")
    }

    @Test func movesIntoAnEmptyNewFolder() throws {
        let (legacy, current) = try scratch()
        try write("# Headroom observations", "log.md", in: legacy)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        #expect(HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(exists(current, "log.md"))
    }

    @Test func nothingToMove() throws {
        let (legacy, current) = try scratch()
        #expect(!HistoryStore.migrateLegacyDirectory(from: legacy, to: current))
        #expect(!exists(current))
    }
}
