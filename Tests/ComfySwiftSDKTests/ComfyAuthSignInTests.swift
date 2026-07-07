import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("ComfyAuth.signIn — interactive sign-in orchestrator")
struct ComfyAuthSignInTests {

    // MARK: - In-memory fakes

    /// An in-memory ``ComfyTokenStore`` fake. `saveError` lets a test force a persistence failure.
    private actor InMemoryTokenStore: ComfyTokenStore {
        private var stored: ComfyStoredTokens?
        private let saveError: Error?

        private(set) var saveCount = 0
        private(set) var clearCount = 0

        init(_ initial: ComfyStoredTokens? = nil, saveError: Error? = nil) {
            self.stored = initial
            self.saveError = saveError
        }

        func load() async throws -> ComfyStoredTokens? { stored }

        func save(_ tokens: ComfyStoredTokens) async throws {
            saveCount += 1
            if let saveError { throw saveError }
            stored = tokens
        }

        func clear() async throws {
            clearCount += 1
            stored = nil
        }
    }

    /// A ``ComfyWebAuthPresenter`` fake that fabricates a canned callback URL from the authorize URL
    /// it is handed — mirroring how the real server echoes back the request's `state`.
    private struct FakePresenter: ComfyWebAuthPresenter {
        enum Behavior: Sendable {
            /// Echo the request's real `state` back with `code` — a valid callback.
            case validCallback(code: String)
            /// Return a callback whose `state` does not match the request's.
            case stateMismatch(code: String)
            /// Return a callback carrying no `code` (the user backed out mid-flow).
            case missingCode
            /// Throw ``ComfyError/authCancelled`` — the user dismissed the sheet.
            case cancel
        }

        let behavior: Behavior
        /// Captures what the SDK handed the presenter, for assertion.
        let seen: CapturedPresentation

        func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
            seen.record(url: url, scheme: callbackURLScheme)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""

            switch behavior {
            case .validCallback(let code):
                return Self.callback(scheme: callbackURLScheme, code: code, state: state)
            case .stateMismatch(let code):
                return Self.callback(scheme: callbackURLScheme, code: code, state: state + "-tampered")
            case .missingCode:
                return URL(string: "\(callbackURLScheme)://oauth-callback?state=\(state)")!
            case .cancel:
                throw ComfyError.authCancelled
            }
        }

        private static func callback(scheme: String, code: String, state: String) -> URL {
            URL(string: "\(scheme)://oauth-callback?code=\(code)&state=\(state)")!
        }
    }

    /// Thread-safe capture of the single presentation the SDK drove.
    private final class CapturedPresentation: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: URL?
        private var _scheme: String?

        func record(url: URL, scheme: String) {
            lock.lock(); defer { lock.unlock() }
            _url = url
            _scheme = scheme
        }

        var url: URL? { lock.lock(); defer { lock.unlock() }; return _url }
        var scheme: String? { lock.lock(); defer { lock.unlock() }; return _scheme }
    }

    /// Thread-safe capture of the arguments the injected exchange closure received, plus a call count.
    private final class CapturedExchange: @unchecked Sendable {
        private let lock = NSLock()
        private var _code: String?
        private var _verifier: String?
        private var _config: OAuthClientConfig?
        private(set) var callCount = 0

        func record(code: String, verifier: String, config: OAuthClientConfig) {
            lock.lock(); defer { lock.unlock() }
            callCount += 1
            _code = code
            _verifier = verifier
            _config = config
        }

        var code: String? { lock.lock(); defer { lock.unlock() }; return _code }
        var verifier: String? { lock.lock(); defer { lock.unlock() }; return _verifier }
        var config: OAuthClientConfig? { lock.lock(); defer { lock.unlock() }; return _config }
        var count: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    }

    private struct StubStoreError: Error {}

    /// A stub exchange that records its inputs and then returns `response` (or throws `error`).
    private func stubExchange(
        capture: CapturedExchange,
        response: OAuthTokenResponse = OAuthTokenResponse(
            accessToken: "signin-access", refreshToken: "signin-refresh", expiresIn: 3600
        ),
        error: Error? = nil
    ) -> @Sendable (String, String, OAuthClientConfig) async throws -> OAuthTokenResponse {
        { code, verifier, config in
            capture.record(code: code, verifier: verifier, config: config)
            if let error { throw error }
            return response
        }
    }

    /// Runs an async throwing closure and returns the `ComfyError` it threw, or `nil`.
    private func comfyError(from body: () async throws -> Void) async -> ComfyError? {
        do {
            try await body()
            return nil
        } catch let error as ComfyError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - Happy path

    @Test("signIn persists the exchanged tokens and returns a refreshable client")
    func signInPersistsAndReturnsRefreshableClient() async throws {
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let presenter = FakePresenter(behavior: .validCallback(code: "auth-code-123"), seen: CapturedPresentation())

        let client = try await ComfyAuth.signIn(
            presenter: presenter,
            store: store,
            config: .comfyIOS,
            exchange: stubExchange(capture: exchange)
        )

        // The returned client authenticates in refreshable mode wired to the store.
        guard case .oauthRefreshable = client.credential else {
            Issue.record("expected an .oauthRefreshable client, got \(client.credential)")
            return
        }

        // Tokens minted by the exchange are persisted.
        let persisted = try #require(await store.load())
        #expect(persisted.accessToken == "signin-access")
        #expect(persisted.refreshToken == "signin-refresh")
        #expect(await store.saveCount == 1)
        // The absolute expiry is `now + expiresIn`.
        #expect(persisted.expiresAt.timeIntervalSinceNow > 3500)
        #expect(persisted.expiresAt.timeIntervalSinceNow <= 3600)
    }

    @Test("signIn feeds the exchange the callback's code and the request's verifier")
    func signInThreadsCodeAndVerifierIntoExchange() async throws {
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let presenter = FakePresenter(behavior: .validCallback(code: "the-code"), seen: CapturedPresentation())

        _ = try await ComfyAuth.signIn(
            presenter: presenter,
            store: store,
            config: .comfyIOS,
            exchange: stubExchange(capture: exchange)
        )

        #expect(exchange.count == 1)
        #expect(exchange.code == "the-code")
        // The verifier is fresh per attempt; assert it's a real PKCE verifier (43 base64url chars),
        // proving the request's own material was threaded through rather than an empty placeholder.
        let verifier = try #require(exchange.verifier)
        #expect(verifier.count == 43)
    }

    @Test("signIn presents the authorize URL and the config's redirect scheme")
    func signInPresentsAuthorizeURLAndScheme() async throws {
        let store = InMemoryTokenStore()
        let seen = CapturedPresentation()
        let presenter = FakePresenter(behavior: .validCallback(code: "c"), seen: seen)

        _ = try await ComfyAuth.signIn(
            presenter: presenter,
            store: store,
            config: .comfyIOS,
            exchange: stubExchange(capture: CapturedExchange())
        )

        let url = try #require(seen.url)
        #expect(url.absoluteString.hasPrefix(
            OAuthConfiguration.authorizationEndpoint.absoluteString + "?"
        ))
        #expect(seen.scheme == OAuthClientConfig.comfyIOS.redirectScheme)
    }

    @Test("signIn threads a custom config through the exchange")
    func signInThreadsCustomConfig() async throws {
        let custom = OAuthClientConfig(
            clientId: "acme-app",
            redirectScheme: "com.acme.app",
            redirectURI: "com.acme.app://cb",
            scopes: ["comfy-cloud:jobs:read"]
        )
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let seen = CapturedPresentation()
        let presenter = FakePresenter(behavior: .validCallback(code: "c"), seen: seen)

        _ = try await ComfyAuth.signIn(
            presenter: presenter,
            store: store,
            config: custom,
            exchange: stubExchange(capture: exchange)
        )

        #expect(exchange.config?.clientId == "acme-app")
        #expect(seen.scheme == "com.acme.app")
    }

    // MARK: - Cancellation & callback-validation propagation

    @Test("signIn propagates .authCancelled when the presenter is dismissed")
    func signInPropagatesAuthCancelledFromPresenter() async throws {
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let presenter = FakePresenter(behavior: .cancel, seen: CapturedPresentation())

        let caught = await comfyError {
            _ = try await ComfyAuth.signIn(
                presenter: presenter, store: store, config: .comfyIOS,
                exchange: stubExchange(capture: exchange)
            )
        }

        guard case .authCancelled = try #require(caught) else {
            Issue.record("expected .authCancelled, got \(String(describing: caught))")
            return
        }
        // A dismissed session never reaches the exchange or the store.
        #expect(exchange.count == 0)
        #expect(await store.saveCount == 0)
        #expect(try await store.load() == nil)
    }

    @Test("signIn maps a code-less callback to .authCancelled")
    func signInMissingCodeMapsToAuthCancelled() async throws {
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let presenter = FakePresenter(behavior: .missingCode, seen: CapturedPresentation())

        let caught = await comfyError {
            _ = try await ComfyAuth.signIn(
                presenter: presenter, store: store, config: .comfyIOS,
                exchange: stubExchange(capture: exchange)
            )
        }

        guard case .authCancelled = try #require(caught) else {
            Issue.record("expected .authCancelled, got \(String(describing: caught))")
            return
        }
        #expect(exchange.count == 0)
        #expect(await store.saveCount == 0)
    }

    @Test("signIn propagates .authStateMismatch on a tampered callback state")
    func signInPropagatesStateMismatch() async throws {
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let presenter = FakePresenter(behavior: .stateMismatch(code: "c"), seen: CapturedPresentation())

        let caught = await comfyError {
            _ = try await ComfyAuth.signIn(
                presenter: presenter, store: store, config: .comfyIOS,
                exchange: stubExchange(capture: exchange)
            )
        }

        guard case .authStateMismatch = try #require(caught) else {
            Issue.record("expected .authStateMismatch, got \(String(describing: caught))")
            return
        }
        // A code we can't state-verify is never redeemed or persisted.
        #expect(exchange.count == 0)
        #expect(await store.saveCount == 0)
    }

    // MARK: - Exchange & persistence failure propagation

    @Test("signIn propagates a ComfyError from the token exchange unchanged")
    func signInPropagatesExchangeError() async throws {
        let store = InMemoryTokenStore()
        let exchange = CapturedExchange()
        let presenter = FakePresenter(behavior: .validCallback(code: "c"), seen: CapturedPresentation())

        let caught = await comfyError {
            _ = try await ComfyAuth.signIn(
                presenter: presenter, store: store, config: .comfyIOS,
                exchange: stubExchange(capture: exchange, error: ComfyError.authInvalid)
            )
        }

        guard case .authInvalid = try #require(caught) else {
            Issue.record("expected .authInvalid, got \(String(describing: caught))")
            return
        }
        // A failed exchange leaves the store untouched.
        #expect(await store.saveCount == 0)
        #expect(try await store.load() == nil)
    }

    @Test("signIn propagates a store save failure")
    func signInPropagatesSaveFailure() async throws {
        let store = InMemoryTokenStore(saveError: StubStoreError())
        let presenter = FakePresenter(behavior: .validCallback(code: "c"), seen: CapturedPresentation())

        await #expect(throws: StubStoreError.self) {
            _ = try await ComfyAuth.signIn(
                presenter: presenter, store: store, config: .comfyIOS,
                exchange: stubExchange(capture: CapturedExchange())
            )
        }
        // The save was attempted; nothing lingers as usable state.
        #expect(await store.saveCount == 1)
        #expect(try await store.load() == nil)
    }
}
