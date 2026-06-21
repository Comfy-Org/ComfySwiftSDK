import Foundation

/// The OAuth token-provider closure, returning a current access token. Implementations must be safe to call concurrently and must not block.
public typealias OAuthTokenProvider = @Sendable () async throws -> String

/// Provides the current refresh token. Never called concurrently; never log the returned value.
public typealias OAuthRefreshProvider = @Sendable () async throws -> String

/// Receives a fresh token pair after a successful silent refresh, for the caller to persist. Throw only on genuine persistence failure, and throw `ComfyError.unknown(underlying:)` rather than `.authInvalid`.
public typealias OAuthTokenStore = @Sendable (OAuthTokenResponse) async throws -> Void

/// Returns the stored access-token expiry, or `nil` if none is stored. Must not block; `nil` is treated as already expired.
public typealias OAuthExpiryProvider = @Sendable () throws -> Date?

/// Credential mode for `ComfyCloudClient`. The credential travels as an HTTP header on API requests and as a `?token=` query parameter on the WebSocket leg.
public enum ComfyCredential: Sendable {
    /// API-key mode. Injects `X-API-Key: <key>` on HTTP requests.
    case apiKey(String)
    /// OAuth Bearer mode where the caller manages token freshness. Calls `tokenProvider` per request and injects `Authorization: Bearer <token>`.
    case oauth(tokenProvider: OAuthTokenProvider)
    /// OAuth Bearer mode where the SDK owns proactive and 401-triggered serialized refresh.
    case oauthRefreshable(
        tokenProvider: OAuthTokenProvider,
        refreshProvider: OAuthRefreshProvider,
        tokenStore: OAuthTokenStore,
        expiryProvider: OAuthExpiryProvider
    )
}
