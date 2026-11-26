import Foundation
import Testing
@testable import HeadroomCore

@Suite struct MemoryTests {
    func app(_ pid: Int32, _ path: String, name: String = "App") -> AppIdentity {
        .init(pid: pid, name: name, bundlePath: path, bundleIdentifier: nil, launchDate: nil)
    }
    @Test func groupsDescendantsAndReparentedHelpersWithoutDoubleCounting() {
        let apps = [app(10, "/Applications/Browser.app"), app(20, "/Applications/Editor.app")]
        let processes = [
            ProcessMemory(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/browser", footprint: 100),
            ProcessMemory(pid: 11, parent: 10, path: "/usr/bin/worker", footprint: 200),
            ProcessMemory(pid: 12, parent: 1, path: "/Applications/Browser.app/Contents/Helper.app/helper", footprint: 300),
            ProcessMemory(pid: 20, parent: 10, path: "/Applications/Editor.app/editor", footprint: 50),
            ProcessMemory(pid: 21, parent: 20, path: "/usr/bin/worker", footprint: 25),
            ProcessMemory(pid: 30, parent: 1, path: "/Applications/Browser.app.fake/worker", footprint: 999)
        ]
        let result = AppGrouping.group(apps: apps, processes: processes)
        #expect(result.map(\.bytes) == [600, 75])
        #expect(result.map(\.processCount) == [3, 2])
    }
    @Test func unreadableProcessesAndParentCycles() {
        let result = AppGrouping.group(apps: [app(10, "/A.app"), app(20, "/B.app")], processes: [
            .init(pid: 10, parent: 1, path: "/A.app/main", footprint: 10),
            .init(pid: 11, parent: 10, path: "/worker", footprint: nil),
            .init(pid: 20, parent: 1, path: "/B.app/main", footprint: nil),
            .init(pid: 30, parent: 31, path: "/worker", footprint: 1000),
            .init(pid: 31, parent: 30, path: "/worker", footprint: 1000)
        ])
        #expect(result[0].bytes == 10)
        #expect(result[0].unreadableCount == 1)
        #expect(result[1].bytes == nil)
    }
    @Test func longestBundlePathOwnsReparentedNestedHelper() {
        let result = AppGrouping.group(apps: [app(10, "/A.app"), app(20, "/A.app/Nested.app")], processes: [
            .init(pid: 21, parent: 1, path: "/A.app/Nested.app/helper", footprint: 50)
        ])
        #expect(result.first?.id == 20)
        #expect(result.first?.bytes == 50)
    }
    @Test func kernelPressureIsNotDerivedFromUsagePercent() {
        #expect(Pressure.fromKernel(1) == .normal)
        #expect(Pressure.fromKernel(2) == .warning)
        #expect(Pressure.fromKernel(4) == .critical)
        #expect(Pressure.fromKernel(6) == .critical)
        #expect(Pressure.fromKernel(0) == .unknown)
    }
    @Test func placementFallsBackWithoutNotch() {
        for placement in Placement.allCases { #expect(!placement.usesNotch(available: false)) }
        #expect(Placement.automatic.usesNotch(available: true))
        #expect(Placement.notch.usesNotch(available: true))
        #expect(!Placement.menuBar.usesNotch(available: true))
    }
    @Test func liveKernelReadAndOwnFootprint() throws {
        let memory = SystemMemory.read()
        #expect(memory.valid)
        #expect(memory.total > 0)
        #expect(memory.used <= memory.total)
        let own = try #require(ProcessMemory.read().first { $0.pid == ProcessInfo.processInfo.processIdentifier })
        #expect((own.footprint ?? 0) > 0)
    }
}
