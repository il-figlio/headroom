import Foundation
import Testing
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
@testable import HeadroomCore

// Claude Code sign-in checks. Every Keychain, HTTP and `claude --version`
// call goes to a fake: the real login Keychain, the network, the real CLI
// and the real ~/.claude are never touched.

private final class FakeKeychain: ClaudeKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var _info: KeychainItemInfo?
    private var _secret: KeychainSecret
    private var _calls = 0
    private var _secretReads = 0

    init(info: KeychainItemInfo? = nil, secret: KeychainSecret = .missing) {
        _info = info; _secret = secret
    }
    var info: KeychainItemInfo? {
        get { lock.lock(); defer { lock.unlock() }; return _info }
        set { lock.lock(); _info = newValue; lock.unlock() }
    }
    var secret: KeychainSecret {
        get { lock.lock(); defer { lock.unlock() }; return _secret }
        set { lock.lock(); _secret = newValue; lock.unlock() }
    }
    /// Attribute and secret reads together.
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var secretReads: Int { lock.lock(); defer { lock.unlock() }; return _secretReads }

    func itemInfo() -> KeychainItemInfo? {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _info
    }
    func readSecret() -> KeychainSecret {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        _secretReads += 1
        return _secret
    }
}

/// A switch a check can flip between fetches.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _on: Bool
    init(_ on: Bool) { _on = on }
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _on }
        set { lock.lock(); _on = newValue; lock.unlock() }
    }
}

private final class FakeHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(URL, [String: String])] = []
    private let respond: @Sendable (URL) -> (Int, String)

    init(respond: @escaping @Sendable (URL) -> (Int, String) = { _ in (200, #"{"five_hour":{"utilization":10}}"#) }) {
        self.respond = respond
    }
    var requests: [(URL, [String: String])] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func record(_ url: URL, _ headers: [String: String]) {
        lock.lock(); _requests.append((url, headers)); lock.unlock()
    }

    var get: QuotaHTTP.Get {
        { url, headers in
            self.record(url, headers)
            let (status, body) = self.respond(url)
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private struct Home {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-check-\(UUID().uuidString)")

    func write(_ relative: String, _ contents: String, executable: Bool = false, modified: Date? = nil) {
        let file = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        var attributes: [FileAttributeKey: Any] = [:]
        if executable { attributes[.posixPermissions] = 0o700 }
        if let modified { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: file.path) }
    }
    func delete(_ relative: String) { try? FileManager.default.removeItem(at: url.appendingPathComponent(relative)) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let expiredFile = #"{"claudeAiOauth":{"accessToken":"file-old","expiresAt":1000}}"#
private let validFile = #"{"claudeAiOauth":{"accessToken":"file-new","expiresAt":4102444800000,"subscriptionType":"max"}}"#
private let keychainRecord = Data(#"{"claudeAiOauth":{"accessToken":"kc-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#.utf8)

private func source(_ keychain: FakeKeychain, allowed: Bool = true, http: FakeHTTP = FakeHTTP()) -> ClaudeQuotaSource {
    ClaudeQuotaSource(keychain: keychain, keychainAllowed: { allowed }, http: http.get)
}

// MARK: - Participation and detection

@Test func keychainOnlyUserGetsAClaudeSource() {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: Date(timeIntervalSince1970: 1)))
    let claude = source(keychain)
    let selection = QuotaSources.select(home: home.url, from: [claude], ante: [])
    #expect(selection.sources.count == 1 && selection.sources.first is ClaudeQuotaSource)
    #expect(!selection.claudeCodeHidden)
    let detected = QuotaSources.detect(home: home.url, from: [claude], ante: [])
    #expect(detected == .init(names: ["Claude (Claude Code — Keychain)"], claudeCodeHidden: false))
}

@Test func detectionNamesFileKeychainAndAnteFile() {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, expiredFile)
    home.write(ClaudeQuotaSource.anteFile, "{}")
    let claude = source(FakeKeychain(info: .init(modified: nil)))
    #expect(QuotaSources.detect(home: home.url, from: [claude], ante: []).names
        == ["Claude (Claude Code — file, Keychain)", "Claude (Ante)"])
}

@Test func keychainSettingOffMakesNoKeychainCalls() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: Date()), secret: .found(keychainRecord))
    let http = FakeHTTP()
    let claude = source(keychain, allowed: false, http: http)
    #expect(QuotaSources.select(home: home.url, from: [claude], ante: []).sources.isEmpty)
    #expect(QuotaSources.detect(home: home.url, from: [claude], ante: []).names.isEmpty)

    home.write(ClaudeQuotaSource.claudeFile, expiredFile)
    let reading = await claude.fetch(home: home.url)
    #expect(reading.error == "Claude sign-in expired — run `claude` to sign in again.")
    #expect(!claude.noteSignInChange(home: home.url))
    #expect(keychain.calls == 0)
    #expect(http.requests.isEmpty)
}

@Test func namedAnteAccountsSuppressClaudeCodeWithoutTouchingKeychain() {
    let home = Home(); defer { home.remove() }
    home.write(AnteClaudeQuotaSource.executablePath, "#!/bin/sh\nexit 1\n", executable: true)
    home.write(AnteClaudeQuotaSource.directory + "/personal.json", "{}")
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let keychain = FakeKeychain(info: .init(modified: Date()))
    let claude = source(keychain)
    let selection = QuotaSources.select(home: home.url, from: [claude])
    #expect(selection.claudeCodeHidden)
    #expect(!selection.sources.contains { $0 is ClaudeQuotaSource })
    #expect(selection.sources.compactMap { ($0 as? AnteClaudeQuotaSource)?.account } == ["personal"])
    let detected = QuotaSources.detect(home: home.url, from: [claude])
    #expect(detected == .init(names: ["Claude (Ante: personal)"], claudeCodeHidden: true))
    #expect(keychain.calls == 0)
}

// MARK: - Credential order and copy

@Test func expiredFileFallsBackToKeychain() async throws {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, expiredFile)
    let keychain = FakeKeychain(info: .init(modified: Date()), secret: .found(keychainRecord))
    let creds = try ClaudeQuotaSource.readCredentials(home: home.url, keychain: keychain)
    #expect(creds.accessToken == "kc-token" && creds.origin == .keychain)

    let http = FakeHTTP()
    let reading = await source(keychain, http: http).fetch(home: home.url)
    #expect(reading.error == nil && reading.plan == "Pro")
    #expect(http.requests.first?.1["Authorization"] == "Bearer kc-token")
}

@Test func validFileWinsWithoutReadingKeychain() throws {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let keychain = FakeKeychain(info: .init(modified: Date()), secret: .found(keychainRecord))
    let creds = try ClaudeQuotaSource.readCredentials(home: home.url, keychain: keychain)
    #expect(creds.accessToken == "file-new" && creds.origin == .claudeFile)
    #expect(keychain.calls == 0)
}

@Test func errorCopyNamesTheRightFix() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.anteFile, #"{"access_token":"a","expires_at":"2000-01-01T00:00:00Z"}"#)
    #expect(await source(FakeKeychain()).fetch(home: home.url).error
        == "Claude sign-in expired — run `ante` to sign in again.")

    let prompt = await source(FakeKeychain(info: .init(modified: nil), secret: .needsPrompt)).fetch(home: home.url)
    #expect(prompt.error
        == "Claude Code's Keychain sign-in can't be read without a prompt. Run `claude` once, or turn off Keychain use in Settings.")

    let expiredKeychain = Data(#"{"claudeAiOauth":{"accessToken":"k","expiresAt":1000}}"#.utf8)
    let stale = await source(FakeKeychain(info: .init(modified: nil), secret: .found(expiredKeychain))).fetch(home: home.url)
    #expect(stale.error == "Claude sign-in expired — run `claude` to sign in again.")

    let empty = Home(); defer { empty.remove() }
    #expect(await source(FakeKeychain()).fetch(home: empty.url).error == "No Claude sign-in found — run `claude` to sign in.")
}

@Test func http401NamesTheSignInsOwnCommand() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.anteFile, #"{"access_token":"a","expires_at":"2099-01-01T00:00:00Z"}"#)
    let reading = await source(FakeKeychain(), http: FakeHTTP { _ in (401, "{}") }).fetch(home: home.url)
    #expect(reading.error == "Claude sign-in expired — run `ante` to sign in again.")
}

// MARK: - Freshness

@Test func fileChangeAfterFailureRetriesAndSaysRefreshing() async {
    let home = Home(); defer { home.remove() }
    let then = Date(timeIntervalSince1970: 1_700_000_000)
    home.write(ClaudeQuotaSource.claudeFile, expiredFile, modified: then)
    let http = FakeHTTP()
    let claude = source(FakeKeychain(), allowed: false, http: http)

    let failed = await claude.fetch(home: home.url)
    #expect(failed.error == "Claude sign-in expired — run `claude` to sign in again.")
    #expect(!claude.noteSignInChange(home: home.url), "nothing changed yet")
    // Still gated: a second fetch replays the cause without a request.
    #expect(await claude.fetch(home: home.url).error?.hasPrefix("Claude sign-in expired") == true)
    #expect(http.requests.isEmpty)

    home.write(ClaudeQuotaSource.claudeFile, validFile, modified: then.addingTimeInterval(60))
    #expect(claude.noteSignInChange(home: home.url))
    #expect(!claude.noteSignInChange(home: home.url), "reported once per change")
    let marked = QuotaSources.markClaudeSignInChanged([failed])
    #expect(marked.first?.error == "Claude Code sign-in changed — refreshing")

    let retried = await claude.fetch(home: home.url)
    #expect(retried.error == nil && retried.windows.map(\.label) == ["5h"])
    #expect(http.requests.count == 1)
}

@Test func keychainChangeAfterFailureIsNoticedWithoutReadingTheSecret() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: Date(timeIntervalSince1970: 1)), secret: .needsPrompt)
    let claude = source(keychain)
    #expect(await claude.fetch(home: home.url).error?.contains("can't be read without a prompt") == true)
    #expect(!claude.noteSignInChange(home: home.url))
    keychain.info = .init(modified: Date(timeIntervalSince1970: 2))
    #expect(claude.noteSignInChange(home: home.url))
}

@Test func markingOnlyTouchesTheFailedClaudeCodeReading() {
    var claudeCode = QuotaReading(provider: .claude); claudeCode.error = "old"
    var ante = QuotaReading(provider: .claude); ante.account = "work"; ante.error = "old"
    let healthy = QuotaReading(provider: .codex)
    let marked = QuotaSources.markClaudeSignInChanged([claudeCode, ante, healthy])
    #expect(marked.map(\.error) == [ClaudeQuotaSource.signInChangedMessage, "old", nil])
}

// MARK: - A cached token never outlives the sign-in it came from

private let accountA = #"{"claudeAiOauth":{"accessToken":"token-a","expiresAt":4102444800000,"subscriptionType":"max"}}"#
private let accountB = #"{"claudeAiOauth":{"accessToken":"token-b","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
private let signedInAt = Date(timeIntervalSince1970: 1_700_000_000)

@Test func accountSwitchIsUsedByTheNextFetch() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, accountA, modified: signedInAt)
    let http = FakeHTTP()
    let claude = source(FakeKeychain(), allowed: false, http: http)
    #expect(await claude.fetch(home: home.url).plan == "Max")
    #expect(await claude.fetch(home: home.url).plan == "Max")

    // `claude` signed in as someone else: nothing failed, the old token
    // hasn't expired, and the file's modification date is all that changed.
    home.write(ClaudeQuotaSource.claudeFile, accountB, modified: signedInAt.addingTimeInterval(60))
    #expect(!claude.noteSignInChange(home: home.url), "no failure, so the minute check stays free")
    let switched = await claude.fetch(home: home.url)
    #expect(switched.error == nil && switched.plan == "Pro")
    #expect(http.requests.map { $0.1["Authorization"] } == ["Bearer token-a", "Bearer token-a", "Bearer token-b"])
}

@Test func deletedSignInIsNeitherSentNorReplayed() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, accountA, modified: signedInAt)
    let http = FakeHTTP()
    let claude = source(FakeKeychain(), allowed: false, http: http)
    #expect(await claude.fetch(home: home.url).windows.map(\.label) == ["5h"])

    home.delete(ClaudeQuotaSource.claudeFile)
    let gone = await claude.fetch(home: home.url)
    #expect(gone.error == "No Claude sign-in found — run `claude` to sign in.")
    #expect(gone.plan == nil && gone.windows.isEmpty, "the removed account's readings aren't replayed")
    #expect(http.requests.count == 1, "the removed account's token isn't sent again")
}

@Test func credentialWithoutExpiryFollowsTheSignInToo() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, #"{"claudeAiOauth":{"accessToken":"forever-a"}}"#, modified: signedInAt)
    let http = FakeHTTP()
    let claude = source(FakeKeychain(), allowed: false, http: http)
    _ = await claude.fetch(home: home.url)
    home.write(ClaudeQuotaSource.claudeFile, #"{"claudeAiOauth":{"accessToken":"forever-b"}}"#,
               modified: signedInAt.addingTimeInterval(60))
    _ = await claude.fetch(home: home.url)
    home.delete(ClaudeQuotaSource.claudeFile)
    #expect(await claude.fetch(home: home.url).error == "No Claude sign-in found — run `claude` to sign in.")
    #expect(http.requests.map { $0.1["Authorization"] } == ["Bearer forever-a", "Bearer forever-b"])
}

@Test func keychainItemChangeRereadsTheSecretOnlyThen() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: signedInAt), secret: .found(keychainRecord))
    let http = FakeHTTP()
    let claude = source(keychain, http: http)
    #expect(await claude.fetch(home: home.url).plan == "Pro")
    #expect(keychain.secretReads == 1)

    // Unchanged item: one attributes-only look, no second secret read.
    let before = keychain.calls
    #expect(await claude.fetch(home: home.url).plan == "Pro")
    #expect(keychain.secretReads == 1 && keychain.calls == before + 1)

    // Claude Code signed in as someone else; only the item's date says so.
    keychain.secret = .found(Data(#"{"claudeAiOauth":{"accessToken":"kc-other","expiresAt":4102444800000,"subscriptionType":"max"}}"#.utf8))
    keychain.info = .init(modified: signedInAt.addingTimeInterval(60))
    let switched = await claude.fetch(home: home.url)
    #expect(switched.error == nil && switched.plan == "Max")
    #expect(keychain.secretReads == 2)
    #expect(http.requests.map { $0.1["Authorization"] } == ["Bearer kc-token", "Bearer kc-token", "Bearer kc-other"])
}

@Test func keychainTokenIsDroppedWhenKeychainUseIsTurnedOff() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: signedInAt), secret: .found(keychainRecord))
    let http = FakeHTTP()
    let allowed = Flag(true)
    let claude = ClaudeQuotaSource(keychain: keychain, keychainAllowed: { allowed.on }, http: http.get)
    #expect(await claude.fetch(home: home.url).error == nil)

    allowed.on = false
    let calls = keychain.calls
    let off = await claude.fetch(home: home.url)
    #expect(off.error == "No Claude sign-in found — run `claude` to sign in.")
    #expect(http.requests.count == 1 && keychain.calls == calls)
}

// MARK: - Forgetting (Limits turned off)

@Test func forgetDropsTheCachedTokenAndTheLastGoodReading() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: signedInAt), secret: .found(keychainRecord))
    let failing = Flag(false)
    let http = FakeHTTP { _ in failing.on ? (500, "{}") : (200, #"{"five_hour":{"utilization":10}}"#) }
    let claude = source(keychain, http: http)
    _ = await claude.fetch(home: home.url)
    _ = await claude.fetch(home: home.url)
    #expect(keychain.secretReads == 1, "the token is cached between fetches")

    failing.on = true
    let dimmed = await claude.fetch(home: home.url)
    #expect(dimmed.error == "Claude usage API returned HTTP 500" && dimmed.windows.count == 1)

    claude.forget()
    let blank = await claude.fetch(home: home.url)
    #expect(keychain.secretReads == 2, "nothing was cached, so the sign-in is read again")
    #expect(blank.error == "Claude usage API returned HTTP 500")
    #expect(blank.windows.isEmpty && blank.plan == nil, "no earlier reading is replayed")
}

@Test func forgetLiftsARetryGateAndTheFailureMemory() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, accountA, modified: signedInAt)
    let http = FakeHTTP { _ in (401, "{}") }
    let claude = source(FakeKeychain(), allowed: false, http: http)
    _ = await claude.fetch(home: home.url)
    #expect(await claude.fetch(home: home.url).error?.contains("next attempt") == true)
    #expect(http.requests.count == 1, "gated")

    claude.forget()
    home.write(ClaudeQuotaSource.claudeFile, accountB, modified: signedInAt.addingTimeInterval(60))
    #expect(!claude.noteSignInChange(home: home.url), "no failure is remembered")
    _ = await claude.fetch(home: home.url)
    #expect(http.requests.count == 2)
}

// MARK: - Request

@Test func usageRequestAsksForModelWindowsAsHeadroom() async throws {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let http = FakeHTTP()
    _ = await source(FakeKeychain(), allowed: false, http: http).fetch(home: home.url)
    let (url, headers) = try #require(http.requests.first)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.anthropic.com" && components.path == "/api/oauth/usage")
    #expect(components.queryItems == [URLQueryItem(name: "cedar_ember", value: "1")])
    // No override: QuotaHTTP.get sends the same "Headroom" user agent as Codex.
    #expect(headers["User-Agent"] == nil)
    #expect(headers["Authorization"] == "Bearer file-new")
}

@Test func badRequestRetriesWithoutTheQuery() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let http = FakeHTTP { url in url.query == nil ? (200, #"{"seven_day":{"utilization":5}}"#) : (400, "{}") }
    let reading = await source(FakeKeychain(), allowed: false, http: http).fetch(home: home.url)
    #expect(http.requests.map { $0.0.query } == ["cedar_ember=1", nil])
    #expect(reading.windows.map(\.label) == ["Week"])
}

/// The real session refuses redirects, so a 3xx reaches the source as-is.
@Test func redirectStatusIsReportedNotFollowed() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let http = FakeHTTP { _ in (302, "") }
    let reading = await source(FakeKeychain(), allowed: false, http: http).fetch(home: home.url)
    #expect(reading.error == "Claude usage API returned HTTP 302")
    #expect(http.requests.count == 1)
}

// MARK: - Keychain query shape (fake SecItemCopyMatching)

@Test func keychainQueriesNeverAllowUI() {
    let queries = QueryLog()
    let keychain = SystemClaudeKeychain { query, result in
        queries.add(query as NSDictionary)
        let dict = query as NSDictionary
        if dict[kSecReturnAttributes] as? Bool == true {
            result?.pointee = [kSecAttrModificationDate as String: Date(timeIntervalSince1970: 5)] as CFDictionary
            return errSecSuccess
        }
        return errSecInteractionNotAllowed
    }
    #expect(keychain.itemInfo() == KeychainItemInfo(modified: Date(timeIntervalSince1970: 5)))
    #expect(keychain.readSecret() == .needsPrompt)
    let logged = queries.all
    #expect(logged.count == 2)
    for query in logged {
        #expect(query[kSecAttrService] as? String == "Claude Code-credentials")
        #expect(query[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUIFail as String)
        #if canImport(LocalAuthentication)
        #expect((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
        #endif
    }
    #expect(logged[0][kSecReturnData] == nil, "existence check never asks for the secret")
    #expect(logged[1][kSecReturnData] as? Bool == true)
}

@Test func keychainStatusMapping() {
    func secret(_ status: OSStatus) -> KeychainSecret { SystemClaudeKeychain { _, _ in status }.readSecret() }
    #expect(secret(errSecItemNotFound) == .missing)
    #expect(secret(errSecAuthFailed) == .needsPrompt)
    #expect(secret(errSecUserCanceled) == .needsPrompt)
    #expect(secret(errSecParam) == .failed(errSecParam))
    #expect(SystemClaudeKeychain { _, _ in errSecItemNotFound }.itemInfo() == nil)
}

private final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [NSDictionary] = []
    var all: [NSDictionary] { lock.lock(); defer { lock.unlock() }; return queries }
    func add(_ query: NSDictionary) { lock.lock(); queries.append(query); lock.unlock() }
}

// MARK: - Per-model windows (fixtures)

private func decode(_ json: String) throws -> QuotaReading {
    let response = try JSONDecoder().decode(ClaudeQuotaSource.Response.self, from: Data(json.utf8))
    return ClaudeQuotaSource.map(response, credentials: .init(accessToken: "x", scopes: [], subscriptionType: "max", expiresAt: nil))
}

@Test func usageWithoutModelFieldsKeepsFiveHourAndWeek() throws {
    let reading = try decode("""
    {"five_hour": {"utilization": 31, "resets_at": "2026-11-24T20:30:00+00:00"},
     "seven_day": {"utilization": 12.5, "resets_at": "2026-11-28T00:00:00Z"},
     "seven_day_opus": null, "unknown_field": {"nested": [1, 2]}}
    """)
    #expect(reading.windows.map(\.label) == ["5h", "Week"])
    #expect(reading.windows[1].usedFraction == 0.125)
    #expect(reading.windows.allSatisfy { $0.resetsAt != nil && $0.detail == nil })
}

@Test func usageWithModelWindowsOrdersThemAfterWeek() throws {
    let reading = try decode("""
    {"five_hour": {"utilization": 31},
     "seven_day": {"utilization": 40, "resets_at": "2026-11-28T00:00:00Z"},
     "seven_day_opus": {"utilization": 80, "resets_at": "2026-11-27T00:00:00Z"},
     "seven_day_sonnet": {"utilization": 22, "resets_at": "2026-11-27T00:00:00Z"},
     "limits": [
       {"weekly_scoped": {"model": "claude-haiku-4-5", "utilization": 5, "resets_at": "2026-11-27T00:00:00Z"}},
       {"type": "weekly_scoped", "scope": "All models", "utilization": 41},
       {"weekly_scoped": [{"display_name": "Sonnet", "utilization": 99}, {"name": "Experimental-Long-Name", "used_percent": "7"}]},
       {"something_else": true}, "garbage", 3]}
    """)
    #expect(reading.windows.map(\.label) == ["5h", "Week", "Sonnet", "Opus", "Haiku", "Experim"])
    #expect(reading.windows[1].usedFraction == 0.40, "seven_day wins over the generic scope")
    #expect(reading.windows[2].usedFraction == 0.22, "seven_day_sonnet wins over a scoped Sonnet")
    #expect(reading.windows[3].detail == "Weekly limit for Opus models")
    #expect(reading.windows[5].usedFraction == 0.07)
    #expect(reading.windows.allSatisfy { $0.label.count <= 7 })
}

@Test func genericScopeFillsMissingWeek() throws {
    let reading = try decode("""
    {"five_hour": {"utilization": "bad"},
     "limits": [{"kind": "weekly_scoped", "scope": {"name": "all_models"}, "utilization": 64, "resets_at": 1795000000},
                {"weekly_scoped": {"scope_name": "fable", "utilization": 12}}]}
    """)
    #expect(reading.windows.map(\.label) == ["Week", "Fable"])
    #expect(reading.windows[0].usedFraction == 0.64 && reading.windows[0].resetsAt != nil)
}

@Test func scopeLabelsFitTheColumn() {
    #expect(ClaudeQuotaSource.scope("claude-opus-4-1") == .model("Opus"))
    #expect(ClaudeQuotaSource.scope("Sonnet 4.5") == .model("Sonnet"))
    #expect(ClaudeQuotaSource.scope("All models") == .generic)
    #expect(ClaudeQuotaSource.scope("claude") == nil)
    #expect(ClaudeQuotaSource.scope("research_preview") == .model("Researc"))
}
