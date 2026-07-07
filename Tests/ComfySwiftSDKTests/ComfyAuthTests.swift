import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("ComfyAuth — token-store credential glue (restoreClient / signOut)")
struct ComfyAuthTests {

    // MARK: - In-memory fakes

    /// An in-memory ``ComfyTokenStore`` fake. `saveError` lets a test force a persistence failure.
    private actor InMemoryTokenStore: ComfyTokenStore {
        private var stored: ComfyStoredTokens?
        private let saveError: Error?

        private(set) var clearCount = 0
        private(set) var saveCount = 0

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

    private struct StubStoreError: Error {}

    /// Runs an async throwing closure and returns the `ComfyError` it threw, or `nil` if it did not
    /// throw a `ComfyError`. Lets tests match on a specific case (`ComfyError` is not `Equatable`,
    /// so `#expect(throws:)` with a case value is unavailable).
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

    private func tokens(
        access: String = "access-abc",
        refresh: String = "refresh-xyz",
        expiresAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> ComfyStoredTokens {
        ComfyStoredTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    /// Extracts the four refreshable-credential closures for direct exercise, failing the test if
    /// the credential is not `.oauthRefreshable`.
    private func refreshableClosures(
        store: ComfyTokenStore,
        initialExpiry: Date?
    ) -> (
        tokenProvider: OAuthTokenProvider,
        refreshProvider: OAuthRefreshProvider,
        tokenStore: OAuthTokenStore,
        expiryProvider: OAuthExpiryProvider
    )? {
        let credential = ComfyAuth.makeRefreshableCredential(store: store, initialExpiry: initialExpiry)
        guard case let .oauthRefreshable(tp, rp, ts, ep) = credential else { return nil }
        return (tp, rp, ts, ep)
    }

    // MARK: - restoreClient: empty store → nil

    @Test("restoreClient returns nil when the store is empty")
    func restoreClientNilWhenEmpty() async throws {
        let store = InMemoryTokenStore(nil)
        let client = try await ComfyAuth.restoreClient(store: store)
        #expect(client == nil)
    }

    @Test("restoreClient returns nil when the stored access token is empty")
    func restoreClientNilWhenAccessTokenEmpty() async throws {
        let store = InMemoryTokenStore(tokens(access: ""))
        let client = try await ComfyAuth.restoreClient(store: store)
        #expect(client == nil)
    }

    @Test("restoreClient rethrows a load failure")
    func restoreClientRethrowsLoadFailure() async throws {
        // A store whose load throws. Distinct from the in-memory fake so only load errors.
        struct FailingLoadStore: ComfyTokenStore {
            func load() async throws -> ComfyStoredTokens? { throw StubStoreError() }
            func save(_ tokens: ComfyStoredTokens) async throws {}
            func clear() async throws {}
        }
        await #expect(throws: StubStoreError.self) {
            _ = try await ComfyAuth.restoreClient(store: FailingLoadStore())
        }
    }

    // MARK: - restoreClient: populated store → a client

    @Test("restoreClient builds a client when the store is populated")
    func restoreClientBuildsClientWhenPopulated() async throws {
        let store = InMemoryTokenStore(tokens())
        let client = try await ComfyAuth.restoreClient(store: store)
        #expect(client != nil)
    }

    // MARK: - Closure adapters: token / refresh providers

    @Test("tokenProvider returns the stored access token")
    func tokenProviderReturnsAccessToken() async throws {
        let store = InMemoryTokenStore(tokens(access: "the-access"))
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let token = try await closures.tokenProvider()
        #expect(token == "the-access")
    }

    @Test("tokenProvider throws .authInvalid when no token is stored")
    func tokenProviderThrowsAuthInvalidWhenMissing() async throws {
        let store = InMemoryTokenStore(nil)
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let caught = await comfyError { _ = try await closures.tokenProvider() }
        guard case .authInvalid = try #require(caught) else {
            Issue.record("expected .authInvalid, got \(String(describing: caught))")
            return
        }
    }

    @Test("refreshProvider returns the stored refresh token")
    func refreshProviderReturnsRefreshToken() async throws {
        let store = InMemoryTokenStore(tokens(refresh: "the-refresh"))
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let token = try await closures.refreshProvider()
        #expect(token == "the-refresh")
    }

    @Test("refreshProvider throws .authExpired when no refresh token is stored")
    func refreshProviderThrowsAuthExpiredWhenMissing() async throws {
        let store = InMemoryTokenStore(tokens(refresh: ""))
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let caught = await comfyError { _ = try await closures.refreshProvider() }
        guard case .authExpired = try #require(caught) else {
            Issue.record("expected .authExpired, got \(String(describing: caught))")
            return
        }
    }

    // MARK: - Closure adapters: a store *read* failure surfaces as .unknown, not an auth error

    /// A store whose `load()` throws a caller-supplied error; `save`/`clear` are no-ops. Lets a test
    /// force a read failure (a Keychain hiccup) independently of the in-memory fake.
    private struct FailingLoadStore: ComfyTokenStore {
        let error: Error
        func load() async throws -> ComfyStoredTokens? { throw error }
        func save(_ tokens: ComfyStoredTokens) async throws {}
        func clear() async throws {}
    }

    @Test("tokenProvider surfaces a load failure as .unknown, NOT .authInvalid")
    func tokenProviderLoadFailureSurfacesAsUnknown() async throws {
        let store = FailingLoadStore(error: StubStoreError())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let caught = await comfyError { _ = try await closures.tokenProvider() }
        guard case .unknown(let underlying) = try #require(caught) else {
            Issue.record("expected .unknown, got \(String(describing: caught))")
            return
        }
        #expect(underlying is StubStoreError)
    }

    @Test("refreshProvider surfaces a load failure as .unknown, NOT .authExpired")
    func refreshProviderLoadFailureSurfacesAsUnknown() async throws {
        let store = FailingLoadStore(error: StubStoreError())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let caught = await comfyError { _ = try await closures.refreshProvider() }
        guard case .unknown(let underlying) = try #require(caught) else {
            Issue.record("expected .unknown, got \(String(describing: caught))")
            return
        }
        #expect(underlying is StubStoreError)
    }

    @Test("tokenProvider surfaces a cancelled load as .cancelled")
    func tokenProviderCancelledLoadSurfacesAsCancelled() async throws {
        let store = FailingLoadStore(error: CancellationError())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let caught = await comfyError { _ = try await closures.tokenProvider() }
        guard case .cancelled = try #require(caught) else {
            Issue.record("expected .cancelled, got \(String(describing: caught))")
            return
        }
    }

    // MARK: - tokenStore closure: failure surfaces as .unknown, not .authInvalid

    @Test("tokenStore closure persists a refreshed pair with an absolute expiry")
    func tokenStorePersistsRefreshedPair() async throws {
        let store = InMemoryTokenStore(tokens())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let response = OAuthTokenResponse(accessToken: "new-a", refreshToken: "new-r", expiresIn: 3600)

        try await closures.tokenStore(response)

        let reloaded = try #require(await store.load())
        #expect(reloaded.accessToken == "new-a")
        #expect(reloaded.refreshToken == "new-r")
        // Absolute expiry is now-relative; assert it lands ~3600s ahead (wide tolerance for CI).
        #expect(reloaded.expiresAt.timeIntervalSinceNow > 3500)
        #expect(reloaded.expiresAt.timeIntervalSinceNow <= 3600)
    }

    @Test("tokenStore closure surfaces a save failure as .unknown, NOT .authInvalid")
    func tokenStoreFailureSurfacesAsUnknown() async throws {
        let store = InMemoryTokenStore(tokens(), saveError: StubStoreError())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let response = OAuthTokenResponse(accessToken: "new-a", refreshToken: "new-r", expiresIn: 3600)

        var caught: ComfyError?
        do {
            try await closures.tokenStore(response)
        } catch let error as ComfyError {
            caught = error
        }

        let unwrapped = try #require(caught)
        guard case .unknown(let underlying) = unwrapped else {
            Issue.record("expected .unknown, got \(unwrapped)")
            return
        }
        #expect(underlying is StubStoreError)
    }

    @Test("tokenStore closure surfaces a cancelled save as .cancelled, NOT .unknown")
    func tokenStoreCancelledSaveSurfacesAsCancelled() async throws {
        let store = InMemoryTokenStore(tokens(), saveError: CancellationError())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: nil))
        let response = OAuthTokenResponse(accessToken: "new-a", refreshToken: "new-r", expiresIn: 3600)

        let caught = await comfyError { try await closures.tokenStore(response) }
        guard case .cancelled = try #require(caught) else {
            Issue.record("expected .cancelled, got \(String(describing: caught))")
            return
        }
    }

    // MARK: - expiryProvider: seeded, and updated after a refresh-save

    @Test("expiryProvider returns the seeded initial expiry")
    func expiryProviderReturnsSeededExpiry() async throws {
        let seed = Date(timeIntervalSince1970: 42_000)
        let store = InMemoryTokenStore(tokens())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: seed))
        #expect(try closures.expiryProvider() == seed)
    }

    @Test("expiryProvider reflects the new expiry after a refresh-save")
    func expiryProviderUpdatesAfterSave() async throws {
        let seed = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryTokenStore(tokens())
        let closures = try #require(refreshableClosures(store: store, initialExpiry: seed))

        #expect(try closures.expiryProvider() == seed)

        let before = Date()
        try await closures.tokenStore(
            OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 1200)
        )
        let updated = try #require(try closures.expiryProvider())
        // The cache moved off the seed to ~now+1200s.
        #expect(updated != seed)
        #expect(updated.timeIntervalSince(before) >= 1200)
        #expect(updated.timeIntervalSince(before) < 1260)
    }

    // MARK: - Expiry math (the OAuthTokenResponse + now → ComfyStoredTokens mapping)

    @Test("stored-tokens mapping adds expiresIn to the reference instant")
    func expiryMathAddsExpiresInToNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let response = OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 3600)
        let stored = ComfyStoredTokens(response: response, now: now)
        #expect(stored.accessToken == "a")
        #expect(stored.refreshToken == "r")
        #expect(stored.expiresAt == Date(timeIntervalSince1970: 1_003_600))
    }

    @Test("stored-tokens mapping handles a zero expiresIn")
    func expiryMathHandlesZeroExpiresIn() {
        let now = Date(timeIntervalSince1970: 500)
        let response = OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 0)
        let stored = ComfyStoredTokens(response: response, now: now)
        #expect(stored.expiresAt == now)
    }

    // MARK: - Secret redaction (ComfyStoredTokens description)

    @Test("ComfyStoredTokens description/debugDescription never leak the plaintext tokens")
    func storedTokensDescriptionRedactsSecrets() {
        let stored = tokens(access: "SECRET-ACCESS", refresh: "SECRET-REFRESH")
        for rendered in [stored.description, stored.debugDescription, "\(stored)"] {
            #expect(!rendered.contains("SECRET-ACCESS"))
            #expect(!rendered.contains("SECRET-REFRESH"))
            #expect(rendered.contains("<redacted>"))
        }
    }

    // MARK: - signOut

    @Test("signOut clears the store")
    func signOutClearsStore() async throws {
        let store = InMemoryTokenStore(tokens())
        try await ComfyAuth.signOut(store: store)
        #expect(await store.clearCount == 1)
        #expect(try await store.load() == nil)
    }
}
