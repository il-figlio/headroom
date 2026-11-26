import Foundation
import Testing
@testable import HeadroomCore

@Suite struct ScreenshotTests {
    @Test func fixturesAreInventedAndInternallyConsistent() throws {
        let demo = ScreenshotFixtures(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(demo.apps.allSatisfy { $0.id < 0 && $0.app.bundlePath.isEmpty })
        #expect(demo.memory.pressure == demo.summary.latestPressure)
        #expect(demo.disk.free == demo.summary.latestDiskFree)
        let lastDisk = try #require(demo.summary.diskPoints.last)
        let lastMemory = try #require(demo.summary.points.last)
        #expect(abs(lastDisk.freeGB - Double(demo.disk.free) / 1_073_741_824) <= 0.001)
        #expect(abs(lastMemory.usedGB - Double(demo.memory.used) / 1_073_741_824) <= 0.001)
        #expect(demo.quotas.filter { $0.provider == .claude }.count == 2)
        #expect(demo.quotas.filter { $0.error != nil }.count == 1)
        #expect(demo.agents.sessions.allSatisfy { $0.projectDir.hasPrefix("/Users/demo/") })
        #expect(!demo.agents.live.isEmpty)
        #expect(!demo.summary.recommendations.isEmpty)
    }
}
