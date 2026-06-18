//
//  BearerInjectionTests.swift
//  ComfySwiftSDKTests
//
//  Story 8.5 AC1/AC2 — Bearer header injection and WebSocket `?token=`
//  JWT injection for `oauthRefreshable` mode. Uses `TestURLProtocol`.
//  No live network.
//
//  Assertion seam note (deviation from the story's test sketch,
//  recorded in the Dev Agent Record): HTTP assertions drive `Transport`
//  directly with a stubbed session — the same seam `CredentialModeTests`
//  uses, because `ComfyCloudClient` owns a private non-stubbed
//  `URLSession` and intercepting it would require live network.
//  WebSocket assertions call `WebSocketSession.buildWebSocketURL`
//  directly, because `URLSessionWebSocketTask` bypasses custom
//  `URLProtocol`s entirely — capturing the WS URL through a stubbed
//  session is impossible without a real connection attempt.
//
//  Story 8.5.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("BearerInjection — Story 8.5 AC1/AC2", .serialized)
struct BearerInjectionTests {

    // MARK: - Helpers

    /// Thread-safe capture box for requests seen by `TestURLProtocol`
    /// (same pattern as `CredentialModeTests.RequestCapture`).
    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
        }

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
    }

    private static let baseURL = URL(string: "https://cloud.comfy.org")!

    private func makeTransport(credential: ComfyCredential) -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: Self.baseURL,
            credential: credential
        )
    }

    /// A minimal `oauthRefreshable` credential whose refresh machinery
    /// is never exercised: the stored expiry is `.distantFuture` (not a
    /// wall-clock offset — review 8-5, LOW: an NTP/clock adjustment
    /// mid-test could push a relative expiry inside the 60s proactive
    /// margin), so `applyAuth` falls through to the plain token read.
    private func makeRefreshableCredential(token: String) -> ComfyCredential {
        .oauthRefreshable(
            tokenProvider: { token },
            refreshProvider: { "unused-refresh-token" },
            tokenStore: { _ in },
            expiryProvider: { Date.distantFuture }
        )
    }

    private func installCapture(status: Int = 200) -> RequestCapture {
        let capture = RequestCapture()
        TestURLProtocol.install { request in
            capture.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, "{}".data(using: .utf8)!)
        }
        return capture
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    // MARK: - AC1: HTTP Bearer header injection

    @Test("oauthRefreshable HTTP request carries Authorization: Bearer and no X-API-Key")
    func oauthRefreshable_http_request_carries_Bearer_header() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: makeRefreshableCredential(token: "test-access-token")
        )
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test("apiKey HTTP request carries X-API-Key and no Authorization (AC1 coexistence regression)")
    func apiKey_http_request_carries_X_API_Key_header() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key"))
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - AC2: WebSocket ?token= JWT injection

    @Test("oauthRefreshable WebSocket URL carries ?token=<jwt>")
    func oauthRefreshable_websocket_url_carries_token_query_param() async throws {
        let url = try await WebSocketSession.buildWebSocketURL(
            baseURL: Self.baseURL,
            credential: makeRefreshableCredential(token: "ws-jwt-token"),
            clientID: "test-client-id"
        )
        #expect(url.scheme == "wss")
        #expect(Self.queryValue("token", in: url) == "ws-jwt-token")
        #expect(Self.queryValue("clientId", in: url) == "test-client-id")
    }

    @Test("oauth WebSocket URL carries ?token=<jwt> (TODO(8.5) resolved for the 8.2 case too)")
    func oauth_websocket_url_carries_token_query_param() async throws {
        let url = try await WebSocketSession.buildWebSocketURL(
            baseURL: Self.baseURL,
            credential: .oauth(tokenProvider: { "ws-jwt-token" }),
            clientID: "test-client-id"
        )
        #expect(Self.queryValue("token", in: url) == "ws-jwt-token")
    }

    @Test("apiKey WebSocket URL byte-identical: ?token=<key> (AC2 coexistence regression)")
    func apiKey_websocket_url_carries_token_query_param() async throws {
        let url = try await WebSocketSession.buildWebSocketURL(
            baseURL: Self.baseURL,
            credential: .apiKey("test-key"),
            clientID: "test-client-id"
        )
        #expect(url.scheme == "wss")
        #expect(url.path == "/ws")
        #expect(Self.queryValue("token", in: url) == "test-key")
        #expect(Self.queryValue("clientId", in: url) == "test-client-id")
    }

    @Test("oauthRefreshable WebSocket URL build fails typed when the provider throws")
    func oauthRefreshable_websocket_provider_failure_throws_authInvalid() async throws {
        struct ProviderFailure: Error {}
        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { throw ProviderFailure() },
            refreshProvider: { "unused" },
            tokenStore: { _ in },
            expiryProvider: { Date.distantFuture }
        )
        do {
            _ = try await WebSocketSession.buildWebSocketURL(
                baseURL: Self.baseURL,
                credential: credential
            )
            Issue.record("Expected .authInvalid, got a URL")
        } catch ComfyError.authInvalid {
            // expected — no unauthenticated socket may open
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("oauthRefreshable WebSocket URL build rejects an empty token")
    func oauthRefreshable_websocket_empty_token_throws_authInvalid() async throws {
        let credential = makeRefreshableCredential(token: "")
        do {
            _ = try await WebSocketSession.buildWebSocketURL(
                baseURL: Self.baseURL,
                credential: credential
            )
            Issue.record("Expected .authInvalid, got a URL")
        } catch ComfyError.authInvalid {
            // expected
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }
}
