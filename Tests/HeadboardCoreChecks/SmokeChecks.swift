import Testing
@testable import HeadboardCore

@Test func quotaPolicyStaleWindowIsTwicePollInterval() {
    #expect(QuotaPolicy.staleAfter == 2 * QuotaPolicy.interval)
}
