import Foundation

/// A stored OAuth token triple: the access token, the refresh token, and the absolute instant the
/// access token expires.
///
/// This is the SDK's storage-facing view of a token pair — the shape apps persist and reload
/// through a ``ComfyTokenStore``. It differs from ``OAuthTokenResponse`` (the wire shape returned
/// by the token endpoint) in one way: the server reports a *relative* `expiresIn` (seconds from
/// now), while persistence needs an *absolute* ``expiresAt`` so a token loaded on a later launch
/// still knows when it lapses. Both tokens are secrets and must never be logged.
public struct ComfyStoredTokens: Sendable {

    /// The Bearer access token attached to API requests. Treat as a secret.
    public let accessToken: String

    /// The refresh token redeemed for new access tokens. Treat as a secret.
    public let refreshToken: String

    /// The absolute instant the access token expires.
    public let expiresAt: Date

    /// Creates a stored token triple.
    ///
    /// - Parameters:
    ///   - accessToken: The Bearer access token. Treat as a secret.
    ///   - refreshToken: The refresh token. Treat as a secret.
    ///   - expiresAt: The absolute instant the access token expires.
    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

extension ComfyStoredTokens {
    /// Maps a token-endpoint response (relative `expiresIn`) plus a reference instant onto stored
    /// tokens with an absolute ``expiresAt``. Internal so the mapping — and its expiry arithmetic —
    /// is exercised by a single well-tested path.
    ///
    /// - Parameters:
    ///   - response: The fresh token pair from the token endpoint.
    ///   - now: The reference instant `response.expiresIn` is measured from — the moment the tokens
    ///     were minted, in practice `Date()` at persist time.
    init(response: OAuthTokenResponse, now: Date) {
        self.init(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }
}

/// A persistence backend for OAuth tokens, injected into ``ComfyAuth`` so the SDK can restore a
/// refreshable client and sign out without knowing how or where tokens are stored.
///
/// Implement this over whatever secure storage the app uses (Keychain, an encrypted file, a
/// test-only in-memory box). The SDK reads through ``load()`` on every token access, writes back
/// through ``save(_:)`` after each silent refresh, and wipes through ``clear()`` on sign-out.
///
/// Implementations must be safe to call concurrently. The stored tokens are secrets and must never
/// be logged.
public protocol ComfyTokenStore: Sendable {

    /// Returns the currently stored tokens, or `nil` if none are stored.
    ///
    /// Called on every access-token read and refresh, so it must be cheap. A thrown error is
    /// surfaced to the caller of the SDK operation that triggered the read.
    func load() async throws -> ComfyStoredTokens?

    /// Persists a fresh token triple, replacing any previously stored tokens.
    ///
    /// Called by the SDK after a successful silent refresh. A thrown error is treated as a genuine
    /// persistence failure by ``ComfyAuth/restoreClient(store:config:)`` and surfaced as
    /// ``ComfyError/unknown(underlying:)`` — never as an auth error.
    func save(_ tokens: ComfyStoredTokens) async throws

    /// Removes any stored tokens. Called by ``ComfyAuth/signOut(store:)``.
    func clear() async throws
}

/// Credential glue that turns a ``ComfyTokenStore`` into a ready-to-use, self-refreshing
/// ``ComfyCloudClient`` — and tears the session down again.
///
/// Instead of hand-writing the four closures of
/// ``ComfyCredential/oauthRefreshable(tokenProvider:refreshProvider:tokenStore:expiryProvider:)``
/// over your storage, inject a ``ComfyTokenStore`` and let ``restoreClient(store:config:)`` adapt
/// it. The returned client owns proactive and 401-triggered refresh; each refresh is written back
/// through the store's ``ComfyTokenStore/save(_:)``.
public enum ComfyAuth {

    /// Restores a refreshable ``ComfyCloudClient`` from tokens held in `store`, or returns `nil`
    /// when there is no usable stored session.
    ///
    /// The store is loaded once up front: if it holds no tokens, or an access token that is empty,
    /// this returns `nil` — the caller should route to sign-in. Otherwise it builds a client in
    /// ``ComfyCredential/oauthRefreshable(tokenProvider:refreshProvider:tokenStore:expiryProvider:)``
    /// mode whose four closures adapt the store:
    ///
    /// - the token provider reads the current access token (throwing
    ///   ``ComfyError/authInvalid`` if it has gone missing or empty),
    /// - the refresh provider reads the current refresh token (throwing
    ///   ``ComfyError/authExpired`` if it has gone missing or empty),
    /// - the token store persists each refreshed pair via ``ComfyTokenStore/save(_:)``, surfacing a
    ///   persistence failure as ``ComfyError/unknown(underlying:)`` — never ``ComfyError/authInvalid``,
    ///   so an infrastructure write error is not misreported as expiry,
    /// - the expiry provider reports when the access token lapses, so the SDK can refresh
    ///   proactively.
    ///
    /// - Parameters:
    ///   - store: The token store to restore from and write refreshes back to.
    ///   - config: The OAuth client config the stored tokens were minted under; its
    ///     ``OAuthClientConfig/clientId`` is sent on the refresh grant. Defaults to
    ///     ``OAuthClientConfig/comfyIOS``.
    /// - Returns: A refreshable client, or `nil` if `store` holds no usable session.
    /// - Throws: Rethrows any error from the initial ``ComfyTokenStore/load()``.
    public static func restoreClient(
        store: ComfyTokenStore,
        config: OAuthClientConfig = .comfyIOS
    ) async throws -> ComfyCloudClient? {
        guard let stored = try await store.load(), !stored.accessToken.isEmpty else {
            return nil
        }
        return ComfyCloudClient(
            credential: makeRefreshableCredential(store: store, initialExpiry: stored.expiresAt),
            config: config
        )
    }

    /// Signs the session out by clearing all stored tokens.
    ///
    /// - Parameter store: The token store to wipe.
    /// - Throws: Rethrows any error from ``ComfyTokenStore/clear()``.
    public static func signOut(store: ComfyTokenStore) async throws {
        try await store.clear()
    }

    /// Builds the four-closure refreshable credential that adapts `store`.
    ///
    /// Internal so the closures' contract — the error each throws, and that a `save` failure maps
    /// to `.unknown` rather than `.authInvalid` — is unit-testable without driving the transport.
    ///
    /// `initialExpiry` seeds the synchronous expiry cache described on ``ExpiryCache``.
    static func makeRefreshableCredential(
        store: ComfyTokenStore,
        initialExpiry: Date?
    ) -> ComfyCredential {
        // The SDK's `expiryProvider` is synchronous, but `store.load()` is async, so the expiry
        // cannot be read from the store on the proactive-refresh check. A last-known expiry is
        // cached in memory instead: seeded from the load that gated `restoreClient`, and refreshed
        // by the `tokenStore` closure on every successful save. Returning `nil` here instead would
        // make the SDK treat the token as always-expired and refresh before *every* request.
        let expiryCache = ExpiryCache(initialExpiry)
        return .oauthRefreshable(
            tokenProvider: {
                guard let tokens = try await store.load(), !tokens.accessToken.isEmpty else {
                    throw ComfyError.authInvalid
                }
                return tokens.accessToken
            },
            refreshProvider: {
                guard let tokens = try await store.load(), !tokens.refreshToken.isEmpty else {
                    throw ComfyError.authExpired
                }
                return tokens.refreshToken
            },
            tokenStore: { response in
                let refreshed = ComfyStoredTokens(response: response, now: Date())
                // A persistence failure must surface as `.unknown` — never `.authInvalid` — so a
                // store write error is not misreported as an invalid credential (matches the
                // existing OAuthTokenStore contract).
                do {
                    try await store.save(refreshed)
                } catch {
                    throw ComfyError.unknown(underlying: error)
                }
                expiryCache.set(refreshed.expiresAt)
            },
            expiryProvider: {
                expiryCache.get()
            }
        )
    }
}

/// A thread-safe in-memory cache of the access token's last-known expiry.
///
/// Bridges the SDK's synchronous ``OAuthExpiryProvider`` to the async ``ComfyTokenStore``: the
/// expiry is seeded at restore time and updated on every successful refresh-save, so the proactive
/// refresh check reads a current value without an async store round-trip.
private final class ExpiryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var expiresAt: Date?

    init(_ initial: Date?) {
        self.expiresAt = initial
    }

    func get() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return expiresAt
    }

    func set(_ date: Date?) {
        lock.lock()
        defer { lock.unlock() }
        expiresAt = date
    }
}
