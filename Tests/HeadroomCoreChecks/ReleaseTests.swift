import Foundation
import Testing
@testable import HeadroomCore

@Suite struct ReleaseTests {
    @Test func numericVersionComparison() throws {
        #expect(try #require(ReleaseVersion("v0.10.0")) > #require(ReleaseVersion("0.9.9")))
        #expect(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"))
        #expect(ReleaseVersion("1.2") != nil)
        for value in ["", "1..2", "1.2.3.4", "1.2-beta", "-1", "١.٢"] {
            #expect(ReleaseVersion(value) == nil, "\(value)")
        }
    }

    @Test func selectsNewestStableReleaseRegardlessOfPublicationOrder() throws {
        let data = Data("""
        [{"tag_name":"v0.8.0","draft":false,"prerelease":false},
         {"tag_name":"v1.0.0","draft":true,"prerelease":false},
         {"tag_name":"v0.9.0","draft":false,"prerelease":true},
         {"tag_name":"v0.7.2","draft":false,"prerelease":false},
         {"tag_name":"nightly","draft":false,"prerelease":false}]
        """.utf8)
        #expect(try GitHubRelease.newest(in: data)?.tag_name == "v0.8.0")
        #expect(try GitHubRelease.newest(in: Data("[]".utf8)) == nil)
        #expect(throws: (any Error).self) { try GitHubRelease.newest(in: Data("{}".utf8)) }
    }
}
