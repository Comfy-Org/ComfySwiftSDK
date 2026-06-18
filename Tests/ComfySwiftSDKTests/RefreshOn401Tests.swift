//
//  RefreshOn401Tests.swift
//  ComfySwiftSDKTests
//
//  Story 8.5 AC3-AC6 — proactive refresh, 401-intercept-retry-once,
//  serialized concurrency, tokenStore-before-retry. Uses
//  `TestURLProtocol`. No live network.
//
//  Mock topology: `Transport`'s stubbed session serves BOTH the API
//  endpoints (`/api/queue`) and the OAuth token endpoint
//  (`/oauth/token`) — `OAuthTokenRefreshExecutor` is constructed with
//  Transport's own session, so a single `TestURLProtocol.handler`
//  observes the whole refresh choreography and can count refresh
//  POSTs (the AC5 `refreshCallCount == 1` invariant).
//
//  Mock realism: the fixture mimics the Keychain write-then-read path
//  — `tokenStore` writes the rotated access token into a lock-guarded
//  `TokenBox`, `tokenProvider` reads it. The `/api/queue` mock decides
//  401-vs-200 by which Bearer token a request actually carries (stale
//  vs refreshed), so test outcomes track the auth state machine rather
//  than fragile call-count choreography.
//
//  Story 8.5.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("RefreshOn401 — Story 8.5 AC3-AC6", .serialized)
struct RefreshOn401Tests {

    // MARK: - Helper types

    /// Thread-safe counter for recording call counts in URL protocol
    /// handlers (which run on URL-loading threads).
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; _count += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    /// Thread-safe access-token slot — the test's stand-in for the
    /// Keychain. `tokenStore` writes it, `tokenProvider` reads it.
    final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _accessToken: String
        init(_ initial: String) { _accessToken = initial }
        var accessToken: String { lock.lock(); defer { lock.unlock() }; return _accessToken }
        func set(_ token: String) { lock.lock(); defer { lock.unlock() }; _accessToken = token }
    }

    /// Thread-safe append-only event log for call-order assertions.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func record(_ event: String) { lock.lock(); defer { lock.unlock() }; _events.append(event) }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    /// One-shot async latch: `wait()` suspends until `signal()` fires.
    /// `signal()` is idempotent; a `wait()` after the signal returns
    /// immediately. Used as the AC5 rendezvous (review 8-5, LOW: the
    /// previous fixed 750ms sleep made the test timing-dependent under
    /// CI load).
    final class AsyncLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func signal() {
            lock.lock()
            let pending = continuations
            signaled = true
            continuations = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signaled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: - Fixtures

    private static let baseURL = URL(string: "https://cloud.comfy.org")!
    private static let staleToken = "current-access-token"
    private static let freshToken = "refreshed-access-token"
    private static let refreshResponseJSON = """
        {"access_token":"refreshed-access-token","refresh_token":"new-refresh-token","expires_in":900}
        """

    /// Build a minimal `oauthRefreshable` credential for testing.
    /// - `tokenBox`: shared access-token slot (Keychain stand-in).
    /// - `expiryOffset`: seconds from now for the stored expiry
    ///   (`nil` → no expiry stored, which Transport treats as expired).
    /// - `tokenStoreCounter` / `eventLog`: optional observers.
    /// - `refreshProviderGate`: optional suspension point inside
    ///   `refreshProvider`, used by the concurrency test to hold the
    ///   coalescing window open until every concurrent 401 interceptor
    ///   has provably arrived (latch rendezvous, not wall-clock).
    private func makeRefreshableCredential(
        tokenBox: TokenBox,
        expiryOffset: TimeInterval?,
        tokenStoreCounter: CallCounter? = nil,
        eventLog: EventLog? = nil,
        refreshProviderGate: (@Sendable () async throws -> Void)? = nil
    ) -> ComfyCredential {
        .oauthRefreshable(
            tokenProvider: { tokenBox.accessToken },
            refreshProvider: {
                if let refreshProviderGate {
                    try await refreshProviderGate()
                }
                return "current-refresh-token"
            },
            tokenStore: { response in
                tokenBox.set(response.accessToken)
                tokenStoreCounter?.increment()
                eventLog?.record("tokenStore")
            },
            expiryProvider: {
                expiryOffset.map { Date().addingTimeInterval($0) }
            }
        )
    }

    private func makeTransport(credential: ComfyCredential) -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: Self.baseURL,
            credential: credential
        )
    }

    private static func ok(_ request: URLRequest, body: String = "{}") -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body.data(using: .utf8)!)
    }

    private static func unauthorized(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, #"{"error":"unauthorized"}"#.data(using: .utf8)!)
    }

    /// Install the standard two-endpoint mock:
    ///   - `POST /oauth/token` → counts into `refreshCounter`, returns
    ///     `refreshStatus` (200 with a rotated pair, or 401 = family
    ///     revoked).
    ///   - `GET /api/queue` → counts into `queueCounter`, captures the
    ///     `Authorization` header into `eventLog`, and answers via
    ///     `queueResponder` (defaults to: 200 iff the request carries
    ///     the refreshed token, 401 otherwise).
    private func installMock(
        refreshCounter: CallCounter,
        queueCounter: CallCounter,
        refreshStatus: Int = 200,
        eventLog: EventLog? = nil,
        queueResponder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? = nil
    ) {
        TestURLProtocol.install { request in
            switch request.url?.path {
            case "/oauth/token":
                refreshCounter.increment()
                eventLog?.record("refresh-endpoint")
                if refreshStatus == 200 {
                    return Self.ok(request, body: Self.refreshResponseJSON)
                }
                return Self.unauthorized(request)
            case "/api/queue":
                queueCounter.increment()
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? "<none>"
                eventLog?.record("queue(\(auth == "Bearer \(Self.freshToken)" ? "fresh" : "stale"))")
                if let queueResponder {
                    return queueResponder(request)
                }
                if auth == "Bearer \(Self.freshToken)" {
                    return Self.ok(request)
                }
                return Self.unauthorized(request)
            default:
                Issue.record("Unexpected request path: \(request.url?.path ?? "<nil>")")
                throw URLError(.badURL)
            }
        }
    }

    // MARK: - AC3: proactive pre-request refresh

    @Test("proactive refresh fires when the token is within the 60s margin")
    func proactive_refresh_fires_when_token_near_expiry() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let eventLog = EventLog()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter, eventLog: eventLog)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 30, eventLog: eventLog)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 1)
        // The request that actually went out carried the FRESH token —
        // the caller never observes a stale token being sent.
        #expect(eventLog.events.contains("queue(fresh)"))
        #expect(!eventLog.events.contains("queue(stale)"))
    }

    @Test("no proactive refresh when the token is far from expiry")
    func no_proactive_refresh_when_token_far_from_expiry() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let eventLog = EventLog()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            eventLog: eventLog,
            queueResponder: { Self.ok($0) }  // accept the stale token: no 401 leg in this test
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300, eventLog: eventLog)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 0)
        #expect(eventLog.events == ["queue(stale)"])
    }

    @Test("proactive refresh fires when no expiry is stored (nil → treated as expired)")
    func proactive_refresh_fires_when_expiry_is_nil() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: nil)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 1)
    }

    // MARK: - AC4: 401-intercept-refresh-retry-once

    @Test("401 triggers exactly one refresh and a successful retry")
    func test401_triggers_refresh_then_successful_retry() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        try await transport.validateAuth()  // must not throw

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 2)  // original 401 + successful retry
        #expect(tokenBox.accessToken == Self.freshToken)  // rotated pair persisted
    }

    @Test("second 401 after a successful refresh surfaces .authExpired, never a loop")
    func second_401_after_refresh_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            queueResponder: { Self.unauthorized($0) }  // ALWAYS 401, even with the fresh token
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
            // expected
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)  // exactly one refresh — retry-once, no loop
        #expect(queueCounter.count == 2)    // original + single retry, nothing further
    }

    @Test("refresh failure (401 on the refresh POST — family revoked) surfaces .authExpired")
    func refresh_failure_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 401
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
            // expected — .authExpired (family revoked), NOT .authInvalid
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 1)  // no retry after a failed refresh
    }

    @Test("apiKey mode 401 still surfaces .authInvalid (no refresh machinery) — regression")
    func apiKey_mode_401_still_surfaces_authInvalid() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            queueResponder: { Self.unauthorized($0) }
        )
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key"))
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
            // expected — pass-through, no .authExpired remap in apiKey mode
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }

        #expect(refreshCounter.count == 0)
        #expect(queueCounter.count == 1)  // no retry in apiKey mode
    }

    // MARK: - AC6: tokenStore persistence before retry

    @Test("tokenStore is called BEFORE the retried request reaches the server")
    func tokenStore_called_before_retry_request() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let tokenStoreCounter = CallCounter()
        let eventLog = EventLog()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter, eventLog: eventLog)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(
                tokenBox: tokenBox,
                expiryOffset: 300,
                tokenStoreCounter: tokenStoreCounter,
                eventLog: eventLog
            )
        )
        try await transport.validateAuth()

        #expect(tokenStoreCounter.count == 1)
        // Exact choreography: stale request → refresh POST → Keychain
        // write (tokenStore) → retry with the fresh token. If the retry
        // ever lands before tokenStore, the order (or the "fresh" label,
        // which can only come from the post-tokenStore TokenBox read)
        // breaks.
        #expect(eventLog.events == ["queue(stale)", "refresh-endpoint", "tokenStore", "queue(fresh)"])
    }

    // MARK: - AC5: serialized refresh under concurrency

    @Test("N concurrent 401s coalesce into exactly one refresh network call")
    func concurrent_401s_trigger_exactly_one_refresh() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        // Rendezvous (review 8-5, LOW — replaces a fixed 750ms sleep):
        // the refresh Task is held inside refreshProvider until the
        // queue mock has SERVED all three stale 401s, so every caller
        // provably enters its 401-intercept leg while the single refresh
        // is still in flight — independent of scheduler timing.
        let staleCounter = CallCounter()
        let allStale401sServed = AsyncLatch()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            queueResponder: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth == "Bearer \(Self.freshToken)" {
                    return Self.ok(request)
                }
                staleCounter.increment()
                if staleCounter.count >= 3 {
                    allStale401sServed.signal()
                }
                return Self.unauthorized(request)
            }
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(
                tokenBox: tokenBox,
                expiryOffset: 300,
                refreshProviderGate: {
                    await allStale401sServed.wait()
                    // The latch guarantees all three stale 401s were
                    // served; this short grace covers only the residual
                    // hop from each caller's 401 throw to its
                    // `performRefresh` entry on the actor. It is not
                    // load-bearing for arrival, unlike the old sleep.
                    try await Task.sleep(for: .milliseconds(100))
                }
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { try await transport.validateAuth() }
            }
            try await group.waitForAll()  // all three must succeed
        }

        // The AC5 invariant — the load-bearing assertion: one refresh
        // window, one network call.
        #expect(refreshCounter.count == 1)
        // Every caller ends in success. The latch makes "3 stale 401s +
        // 3 fresh retries" the expected choreography, but the bound is
        // deliberately loose (review 8-5): the queue-call count is not
        // the AC5 contract, refreshCounter is.
        #expect(queueCounter.count >= 3)
    }
}
