import Foundation
import Security
import Testing
@testable import HeadroomCore

/// Credential parsing, response mapping and source gating, in a throwaway
/// home with fake tokens. The Claude source gets no Keychain and an HTTP
/// closure that fails the check if it is ever called.
@Suite struct QuotaTests {
    private let home: URL

    init() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString)")
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: home) }

    private func write(_ relative: String, _ contents: String) {
        let url = home.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A Claude source that can reach neither the Keychain nor the network.
    private func offlineClaude() -> ClaudeQuotaSource {
        ClaudeQuotaSource(keychain: UnusedKeychain(), keychainAllowed: { false }, http: { url, _ in
            Issue.record("unexpected request to \(url)")
            throw URLError(.notConnectedToInternet)
        })
    }

    // MARK: - Credential reading

    @Test func codexCredentialsFromOAuthTokens() throws {
        defer { cleanUp() }
        write(".codex/auth.json", """
        {"OPENAI_API_KEY": null, "auth_mode": "chatgpt", "last_refresh": "2026-10-14T00:00:00Z",
         "tokens": {"access_token": "at-abc", "refresh_token": "rt", "id_token": "it",
                    "account_id": "acct-123"}}
        """)
        let creds = try CodexQuotaSource.readCredentials(home: home)
        #expect(creds.accessToken == "at-abc")
        #expect(creds.accountID == "acct-123")
        #expect(!creds.apiKeyOnly)
    }

    @Test func codexCredentialsAPIKeyOnly() throws {
        defer { cleanUp() }
        write(".codex/auth.json", #"{"OPENAI_API_KEY": "sk-abc"}"#)
        let creds = try CodexQuotaSource.readCredentials(home: home)
        #expect(creds.apiKeyOnly)
    }

    @Test func codexCredentialsMissing() {
        #expect(throws: (any Error).self) { try CodexQuotaSource.readCredentials(home: home) }
    }

    @Test func codexAccountIDFromJWT() throws {
        defer { cleanUp() }
        // Payload: {"https://api.openai.com/auth": {"chatgpt_account_id": "acct-jwt"}}
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-jwt"}}"#.utf8)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "header.\(b64).sig"
        write(".codex/auth.json", """
        {"tokens": {"access_token": "at", "id_token": "\(jwt)"}}
        """)
        let creds = try CodexQuotaSource.readCredentials(home: home)
        #expect(creds.accountID == "acct-jwt")
    }

    @Test func claudeCredentials() throws {
        defer { cleanUp() }
        write(".claude/.credentials.json", """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "refreshToken": "rt",
         "expiresAt": 1893456000000, "scopes": ["user:profile", "user:inference"],
         "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}}
        """)
        let creds = try ClaudeQuotaSource.readCredentials(home: home)
        #expect(creds.accessToken == "sk-ant-oat-x")
        #expect(creds.subscriptionType == "max")
        #expect(creds.scopes == ["user:profile", "user:inference"])
        #expect(creds.expiresAt != nil)
    }

    @Test func claudeCredentialsMissing() {
        // No Keychain passed: the real login Keychain is never consulted.
        #expect(throws: (any Error).self) { try ClaudeQuotaSource.readCredentials(home: home) }
    }

    @Test func anteOAuthFileNeedsNoKeychain() throws {
        defer { cleanUp() }
        write(".ante/auth/credentials/oauth/anthropic.json", #"{"access_token":"ante-token","refresh_token":"owned-by-ante","expires_at":"2099-01-01T00:00:00Z","scopes":["user:profile"]}"#)
        let creds = try ClaudeQuotaSource.readCredentials(home: home)
        #expect(creds.accessToken == "ante-token")
        #expect(creds.expiresAt != nil)
        #expect(QuotaSources.credentialed(home: home).map(\.provider) == [.claude])
    }

    @Test func validAnteCredentialsReplaceExpiredClaudeFile() throws {
        defer { cleanUp() }
        write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1}}"#)
        write(".ante/auth/credentials/oauth/anthropic.json", #"{"access_token":"fresh","expires_at":"2099-01-01T00:00:00.123456Z"}"#)
        let creds = try ClaudeQuotaSource.readCredentials(home: home)
        #expect(creds.accessToken == "fresh")
        #expect(creds.expiresAt != nil)
    }

    @Test func anteCredentialsWithInvalidExpiryAreRejected() {
        defer { cleanUp() }
        write(".ante/auth/credentials/oauth/anthropic.json", #"{"access_token":"token","expires_at":"not-a-date"}"#)
        #expect(throws: (any Error).self) { try ClaudeQuotaSource.readCredentials(home: home) }
    }

    @Test func expiredAnteCredentialsRemainUnchanged() async throws {
        defer { cleanUp() }
        let record = #"{"access_token":"expired","refresh_token":"owned-by-ante","expires_at":"2000-01-01T00:00:00Z"}"#
        write(".ante/auth/credentials/oauth/anthropic.json", record)
        let reading = await offlineClaude().fetch(home: home)
        #expect(reading.error?.contains("sign-in expired") == true)
        let stored = try String(contentsOf: home.appendingPathComponent(".ante/auth/credentials/oauth/anthropic.json"), encoding: .utf8)
        #expect(stored == record)
    }

    @Test func claudeKeychainConsentIsNotInteractive() {
        let attempts = Counter()
        let keychain = SystemClaudeKeychain { query, _ in
            attempts.increment()
            let attributes = query as NSDictionary
            #expect(attributes[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUIFail as String)
            return errSecInteractionNotAllowed
        }
        #expect(keychain.readSecret() == .needsPrompt)
        #expect(attempts.value == 1)
    }

    @Test func claudeExpiredCredentialsRemainUnchanged() async throws {
        defer { cleanUp() }
        let record = #"{"claudeAiOauth":{"accessToken":"expired","refreshToken":"must-not-rotate","expiresAt":1}}"#
        write(".claude/.credentials.json", record)
        let reading = await offlineClaude().fetch(home: home)
        #expect(reading.error?.contains("sign-in expired") == true)
        let stored = try String(contentsOf: home.appendingPathComponent(".claude/.credentials.json"), encoding: .utf8)
        #expect(stored == record)
    }

    // MARK: - Response mapping

    @Test func codexUsageMapping() throws {
        let json = """
        {"account_id": "acct-1", "plan_type": "pro",
         "rate_limit": {
           "primary_window":   {"used_percent": 42, "reset_at": 1760400000, "limit_window_seconds": 18000},
           "secondary_window": {"used_percent": 7,  "reset_at": 1761000000, "limit_window_seconds": 604800}},
         "credits": {"has_credits": true, "unlimited": false, "balance": 150.0},
         "additional_rate_limits": [
           {"limit_name": "GPT-5-Spark", "metered_feature": "codex_spark",
            "rate_limit": {"primary_window": {"used_percent": 3, "reset_at": 1760400000,
                                             "limit_window_seconds": 18000}}}]}
        """
        let response = try JSONDecoder().decode(CodexQuotaSource.Response.self, from: Data(json.utf8))
        let reading = CodexQuotaSource.map(response)
        #expect(reading.provider == .codex)
        #expect(reading.plan == "Pro")
        try #require(reading.windows.count == 3)
        #expect(reading.windows[0].label == "5h")
        #expect(abs(reading.windows[0].usedFraction - 0.42) < 0.001)
        #expect(reading.windows[1].label == "Week")
        #expect(reading.windows[2].label == "GPT-5-Spark · 5h")
        #expect(reading.balance == "150 credits")
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_760_400_000))
    }

    @Test func codexUnlimitedCredits() throws {
        let json = """
        {"plan_type": "team", "credits": {"has_credits": true, "unlimited": true}}
        """
        let response = try JSONDecoder().decode(CodexQuotaSource.Response.self, from: Data(json.utf8))
        let reading = CodexQuotaSource.map(response)
        #expect(reading.balance == "unlimited credits")
        #expect(reading.windows.isEmpty)
    }

    @Test func claudeUsageMapping() throws {
        let json = """
        {"five_hour": {"utilization": 55.4, "resets_at": "2026-10-14T20:30:00+00:00"},
         "seven_day": {"utilization": 12.0, "resets_at": "2026-10-20T00:00:00+00:00"},
         "seven_day_opus": {"utilization": 80.0, "resets_at": "2026-10-18T00:00:00+00:00"},
         "extra_usage": {"is_enabled": true, "monthly_limit": 600, "used_credits": 43443,
                         "utilization": 72, "currency": "USD"}}
        """
        let response = try JSONDecoder().decode(ClaudeQuotaSource.Response.self, from: Data(json.utf8))
        let creds = ClaudeQuotaSource.Credentials(accessToken: "x", scopes: [], subscriptionType: "max", expiresAt: nil)
        let reading = ClaudeQuotaSource.map(response, credentials: creds)
        #expect(reading.provider == .claude)
        #expect(reading.plan == "Max")
        try #require(reading.windows.count == 3)
        #expect(reading.windows[0].label == "5h")
        #expect(abs(reading.windows[0].usedFraction - 0.554) < 0.001)
        #expect(reading.windows[0].resetsAt != nil)
        #expect(reading.windows[2].label == "Opus")
        #expect(reading.balance == "$434.43 of $600 extra usage")
    }

    @Test func claudeUsageMinimal() throws {
        let json = #"{"five_hour": {"utilization": 0, "resets_at": "2026-10-14T20:00:00Z"}}"#
        let response = try JSONDecoder().decode(ClaudeQuotaSource.Response.self, from: Data(json.utf8))
        let reading = ClaudeQuotaSource.map(response, credentials: .init(accessToken: "x", scopes: [], subscriptionType: nil, expiresAt: nil))
        #expect(reading.windows.count == 1)
        #expect(reading.plan == nil)
        #expect(reading.balance == nil)
    }

    // MARK: - Source gating

    @Test func credentialedSourcesFollowDisk() {
        defer { cleanUp() }
        #expect(QuotaSources.credentialed(home: home).isEmpty)
        write(".codex/auth.json", #"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#)
        #expect(QuotaSources.credentialed(home: home).count == 1)
        write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"at"}}"#)
        #expect(QuotaSources.credentialed(home: home).count == 2)
    }

    @Test func namedAnteClaudeAccountsUseTheCLIButKeepCodex() async throws {
        defer { cleanUp() }
        write(".codex/auth.json", "{}")
        write(".claude/.credentials.json", "{}")
        write(".ante/auth/credentials/oauth/anthropic/personal.json", "{}")
        write(".ante/auth/credentials/oauth/anthropic/work.json", "{}")
        write(".ante/bin/ante", """
        #!/bin/sh
        [ "$1" = usage ] && [ "$3" = --json ] || exit 1
        printf '{"subscriptions":[{"credential":"%s","provider":"anthropic","status":"ready","plan":"Max","windows":[{"label":"Current session","used_percent":25,"resets_at":"2026-11-24T10:30:00Z"},{"label":"Fable","used_percent":42}]}]}' "$2"
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: home.appendingPathComponent(".ante/bin/ante").path)
        let sources = QuotaSources.credentialed(home: home)
        #expect(sources.map(\.provider) == [.codex, .claude, .claude])

        // Only the two Ante sources are fetched: they run the stub script above.
        let readings = await QuotaFetcher.fetchAll(sources: Array(sources.dropFirst()), home: home)
        #expect(readings.map(\.id) == ["claude/personal", "claude/work"])
        #expect(readings.map { $0.windows.map(\.label) } == [["5h", "Fable"], ["5h", "Fable"]])
        #expect(readings.first?.windows.first?.usedFraction == 0.25)
        #expect(readings.first?.windows.first?.resetsAt != nil)
        #expect(readings.allSatisfy { $0.plan == "Max" && $0.error == nil })
    }
}

/// Stands in where a Keychain is required but must never be consulted.
private struct UnusedKeychain: ClaudeKeychain {
    func itemInfo() -> KeychainItemInfo? {
        Issue.record("Keychain attributes were read")
        return nil
    }
    func readSecret() -> KeychainSecret {
        Issue.record("Keychain secret was read")
        return .missing
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
