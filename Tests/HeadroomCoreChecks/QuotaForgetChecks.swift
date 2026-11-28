import Foundation
import Testing
@testable import HeadroomCore

// Background forgets (Limits turned off) and the poll that follows them.
// No source, file or network is involved: the forgets are plain closures.

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [String] = []
    var list: [String] { lock.lock(); defer { lock.unlock() }; return _list }
    func add(_ event: String) { lock.lock(); _list.append(event); lock.unlock() }
}

@Test func aPollWaitsForEveryPendingForget() async {
    let forgetting = PendingForget()
    let events = Events()
    forgetting.start {
        try? await Task.sleep(for: .milliseconds(100))
        events.add("first forget")
    }
    forgetting.start { events.add("second forget") }
    await forgetting.wait()
    events.add("fetch")
    #expect(events.list == ["first forget", "second forget", "fetch"])
}

@Test func waitingWithNothingPendingReturns() async {
    let forgetting = PendingForget()
    await forgetting.wait()
    forgetting.start {}
    await forgetting.wait()
    await forgetting.wait()
}
