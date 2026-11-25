import Foundation
import Testing
@testable import HeadboardCore

private let releaseZip = "https://github.com/il-figlio/headboard/releases/download/v0.9.0/Headboard-0.9.0-universal.zip"

/// packaging/app.env is the single source of app values for the release scripts.
private func packagingConfig() throws -> [String: String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("packaging/app.env"), encoding: .utf8)
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 { values[pair[0]] = pair[1] }
    }
    return values
}

@Test func updateConstantsMatchPackagingConfig() throws {
    let config = try packagingConfig()
    #expect(UpdatePolicy.feedURL.absoluteString == config["FEED_URL"])
    #expect(UpdatePolicy.repository == config["GITHUB_REPO"])
    #expect(UpdatePolicy.releasesPageURL.absoluteString == "https://github.com/\(UpdatePolicy.repository)/releases")
    #expect(UpdatePolicy.releasesAPIURL.absoluteString.hasPrefix("https://api.github.com/repos/\(UpdatePolicy.repository)/releases"))
}

@Test func feedIsPublicRawAppcastOnMain() {
    #expect(UpdatePolicy.feedURL.absoluteString == "https://raw.githubusercontent.com/il-figlio/headboard/main/appcast.xml")
}

@Test(arguments: [releaseZip, "https://github.com/il-figlio/headboard/releases/download/v10.20.30/Headboard.zip"])
func acceptsPublicReleaseZips(_ value: String) {
    #expect(UpdatePolicy.allowsArchive(URL(string: value)))
}

@Test(arguments: [
    releaseZip.replacingOccurrences(of: "https:", with: "http:"),
    releaseZip.replacingOccurrences(of: "github.com", with: "github.com.evil.test"),
    releaseZip.replacingOccurrences(of: "github.com", with: "user@github.com"),
    releaseZip.replacingOccurrences(of: "github.com", with: "github.com:8443"),
    releaseZip.replacingOccurrences(of: "il-figlio/headboard", with: "il-figlio/other"),
    releaseZip.replacingOccurrences(of: "il-figlio/headboard", with: "someone/headboard"),
    releaseZip.replacingOccurrences(of: "/download/", with: "/download/latest/"),
    releaseZip.replacingOccurrences(of: "v0.9.0", with: "0.9.0"),
    releaseZip.replacingOccurrences(of: "v0.9.0", with: "v0.9.0-beta"),
    releaseZip.replacingOccurrences(of: ".zip", with: ".dmg"),
    releaseZip.replacingOccurrences(of: "Headboard-0.9.0-universal.zip", with: "..%2Fevil.zip"),
    releaseZip + "?redirect=evil", releaseZip + "#fragment", releaseZip + "/extra",
    "https://github.com/il-figlio/headboard/archive/refs/tags/v0.9.0.zip",
    "https://release-assets.githubusercontent.com/github-production-release-asset/1/Headboard.zip",
    "https://api.github.com/repos/il-figlio/headboard/releases/assets/1234"
])
func rejectsOtherArchiveLocations(_ value: String) {
    #expect(!UpdatePolicy.allowsArchive(URL(string: value)))
}

@Test func rejectsMissingArchiveURL() {
    #expect(!UpdatePolicy.allowsArchive(nil))
}

@Test func recognizesGitHubReleaseAssetRedirect() {
    #expect(UpdatePolicy.allowsDownloadRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sp=r&sig=x")))
    #expect(UpdatePolicy.allowsDownloadRedirect(URL(string: "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/abc")))
    #expect(!UpdatePolicy.allowsDownloadRedirect(URL(string: "https://release-assets.githubusercontent.com.evil.test/a")))
    #expect(!UpdatePolicy.allowsDownloadRedirect(URL(string: "http://release-assets.githubusercontent.com/a")))
    #expect(!UpdatePolicy.allowsDownloadRedirect(URL(string: "https://raw.githubusercontent.com/il-figlio/headboard/main/appcast.xml")))
}
