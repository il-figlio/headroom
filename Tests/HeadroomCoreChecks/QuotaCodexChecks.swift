import Foundation
import Testing
@testable import HeadroomCore

// Codex usage checks. Requests go to an injected closure and the sign-in is
// a fake token in a throwaway home: chatgpt.com and ~/.codex are never touched.

private final class FakeCodexHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(URL, [String: String])] = []
    private var _reply: Result<(Int, String), URLError>

    init(_ status: Int = 200, _ body: String = "{}") { _reply = .success((status, body)) }
    var requests: [(URL, [String: String])] { lock.lock(); defer { lock.unlock() }; return _requests }
    func reply(_ status: Int, _ body: String) { lock.lock(); _reply = .success((status, body)); lock.unlock() }
    func fail(_ code: URLError.Code) { lock.lock(); _reply = .failure(URLError(code)); lock.unlock() }

    var get: QuotaHTTP.Get {
        { url, headers in
            let (status, body) = try self.record(url, headers).get()
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func record(_ url: URL, _ headers: [String: String]) -> Result<(Int, String), URLError> {
        lock.lock(); defer { lock.unlock() }
        _requests.append((url, headers))
        return _reply
    }
}

private let goodBody = """
{"plan_type": "plus", "rate_limit": {
   "primary_window": {"used_percent": 42, "reset_at": 1760400000, "limit_window_seconds": 18000},
   "secondary_window": {"used_percent": 7, "reset_at": 1761000000, "limit_window_seconds": 604800}}}
"""

@Suite struct QuotaCodexChecks {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-check-\(UUID().uuidString)")

    private func signIn() {
        let file = home.appendingPathComponent(".codex/auth.json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(#"{"tokens":{"access_token":"fake-codex-token","account_id":"acct-fake"}}"#.utf8).write(to: file)
    }
    private func cleanUp() { try? FileManager.default.removeItem(at: home) }

    private func map(_ json: String) throws -> QuotaReading {
        CodexQuotaSource.map(try JSONDecoder().decode(CodexQuotaSource.Response.self, from: Data(json.utf8)))
    }

    // MARK: - Lenient decoding: a bad field costs only itself

    @Test func percentAsANumericStringIsAccepted() throws {
        let reading = try map(#"{"rate_limit": {"primary_window": {"used_percent": "42.5", "limit_window_seconds": "18000"}}}"#)
        #expect(reading.windows == [QuotaWindow(label: "5h", usedFraction: 0.425)])
    }

    @Test func unusablePercentDropsOnlyThatWindow() throws {
        for bad in [#""used_percent": "lots","#, #""used_percent": null,"#, #""used_percent": [1],"#, ""] {
            let reading = try map("""
            {"plan_type": "pro", "rate_limit": {
               "primary_window": {\(bad) "limit_window_seconds": 18000},
               "secondary_window": {"used_percent": 7, "limit_window_seconds": 604800}}}
            """)
            #expect(reading.windows.map(\.label) == ["Week"], "\(bad)")
            #expect(reading.plan == "Pro", "\(bad)")
        }
    }

    @Test func resetTimeMayBeEpochSecondsOrISO8601() throws {
        let expected = Date(timeIntervalSince1970: 1_760_400_000)
        for reset in ["1760400000", "1760400000.0", #""1760400000""#, #""2025-10-14T00:00:00Z""#, #""2025-10-14T00:00:00.000+00:00""#] {
            let reading = try map(#"{"rate_limit": {"primary_window": {"used_percent": 1, "reset_at": \#(reset)}}}"#)
            #expect(reading.windows.first?.resetsAt == expected, "\(reset)")
        }
    }

    @Test func unusableResetTimeKeepsTheWindow() throws {
        for reset in [#""soon""#, "true", "{}", "null"] {
            let reading = try map(#"{"rate_limit": {"primary_window": {"used_percent": 30, "reset_at": \#(reset), "limit_window_seconds": 86400}}}"#)
            #expect(reading.windows == [QuotaWindow(label: "Day", usedFraction: 0.3)], "\(reset)")
        }
    }

    @Test func additionalLimitsThatAreNotAListAreIgnored() throws {
        for extra in [#""none""#, "7", #"{"limit_name": "x"}"#, "null"] {
            let reading = try map("""
            {"rate_limit": {"primary_window": {"used_percent": 42, "limit_window_seconds": 18000}},
             "additional_rate_limits": \(extra)}
            """)
            #expect(reading.windows.map(\.label) == ["5h"], "\(extra)")
        }
    }

    @Test func additionalLimitsDecodeIndependently() throws {
        let reading = try map("""
        {"additional_rate_limits": [
           "junk", 3, null,
           {"limit_name": 9, "metered_feature": "codex_spark",
            "rate_limit": {"primary_window": {"used_percent": "3", "limit_window_seconds": 18000},
                           "secondary_window": "soon"}},
           {"limit_name": "Broken", "rate_limit": []},
           {"limit_name": "GPT-5-Spark", "rate_limit": {"secondary_window": {"used_percent": 9, "limit_window_seconds": 604800}}},
           {"limit_name": "Third", "rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000}}}]}
        """)
        // Unusable entries don't count towards the two extra limits shown.
        #expect(reading.windows.map(\.label) == ["codex_spark · 5h", "GPT-5-Spark · Week"])
        #expect(reading.windows.first?.usedFraction == 0.03)
    }

    @Test func oddTopLevelFieldsDropOnlyThemselves() throws {
        let reading = try map("""
        {"plan_type": 7, "account_id": ["x"], "rate_limit": "none",
         "credits": {"has_credits": "yes", "unlimited": 0, "balance": "12.4"},
         "rate_limit_reset_credits": {"available_count": "2"},
         "something_new": {"nested": [1, 2]}}
        """)
        #expect(reading.plan == nil && reading.windows.isEmpty)
        #expect(reading.balance == "2 resets", "has_credits wasn't a boolean, so the balance isn't claimed")
        #expect(try map(#"{"plan_type": "team", "credits": "n/a", "rate_limit_reset_credits": 3}"#).plan == "Team")
    }

    @Test func aBodyThatIsNotAnObjectDoesNotDecode() {
        for body in ["[1, 2]", #""ok""#, "42", "not json", ""] {
            #expect(throws: (any Error).self, "\(body)") {
                try JSONDecoder().decode(CodexQuotaSource.Response.self, from: Data(body.utf8))
            }
        }
    }

    // MARK: - Fetch: what each kind of reply is reported as

    @Test func requestGoesToChatGPTWithTheSignInsHeaders() async throws {
        signIn(); defer { cleanUp() }
        let http = FakeCodexHTTP(200, goodBody)
        let reading = await CodexQuotaSource(http: http.get).fetch(home: home)
        #expect(reading.error == nil && reading.plan == "Plus" && reading.windows.map(\.label) == ["5h", "Week"])
        let (url, headers) = try #require(http.requests.first)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(headers == ["Authorization": "Bearer fake-codex-token", "ChatGPT-Account-Id": "acct-fake"])
        #expect(http.requests.count == 1)
    }

    @Test func oddFieldsAreNotANetworkError() async {
        signIn(); defer { cleanUp() }
        let http = FakeCodexHTTP(200, """
        {"plan_type": "pro", "additional_rate_limits": "none", "rate_limit": {
           "primary_window": {"used_percent": "42", "reset_at": "2025-10-14T00:00:00Z", "limit_window_seconds": 18000},
           "secondary_window": {"reset_at": "later", "limit_window_seconds": 604800}}}
        """)
        let reading = await CodexQuotaSource(http: http.get).fetch(home: home)
        #expect(reading.error == nil)
        #expect(reading.windows == [QuotaWindow(label: "5h", usedFraction: 0.42, resetsAt: Date(timeIntervalSince1970: 1_760_400_000))])
    }

    @Test func undecodableReplyIsAnUnexpectedResponseAndKeepsTheLastReading() async {
        signIn(); defer { cleanUp() }
        let http = FakeCodexHTTP(200, goodBody)
        let codex = CodexQuotaSource(http: http.get)
        #expect(await codex.fetch(home: home).error == nil)
        // Not JSON, not an object, or an object with nothing Headroom reads.
        for body in ["<html>Just a moment…</html>", "[1, 2]", "{}", #"{"detail": "moved"}"#] {
            http.reply(200, body)
            let reading = await codex.fetch(home: home)
            #expect(reading.error == "Codex usage API returned an unexpected response", "\(body)")
            #expect(reading.windows.map(\.label) == ["5h", "Week"], "\(body)")
        }
    }

    @Test func aFailedRequestIsStillANetworkError() async {
        signIn(); defer { cleanUp() }
        let http = FakeCodexHTTP()
        http.fail(.notConnectedToInternet)
        let reading = await CodexQuotaSource(http: http.get).fetch(home: home)
        #expect(reading.error?.hasPrefix("Network error: ") == true)
    }
}
