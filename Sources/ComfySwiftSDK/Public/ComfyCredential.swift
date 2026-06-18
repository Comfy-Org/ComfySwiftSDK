//
//  ComfyCredential.swift
//  ComfySwiftSDK
//
//  Credential mode for `ComfyCloudClient`. Pure data type — no methods,
//  no logic. The app constructs one of these and hands it to
//  `ComfyCloudClient.init(credential:)`; `Transport` and
//  `WebSocketSession` switch on it when injecting auth.
//
//  Story 8.2 (two-mode credential), Story 8.5 (oauthRefreshable with serialized refresh).
//

import Foundation

/// Convenience alias for the OAuth token-provider closure. The provider
/// is called by the SDK whenever an outbound request needs a current
/// access token.
///
/// Implementations must be safe to call concurrently: the SDK may invoke
/// the provider from multiple in-flight requests at once and does not
/// deduplicate calls. For `oauth(tokenProvider:)`, token freshness and
/// refresh remain the provider's responsibility; for `oauthRefreshable`,
/// the SDK owns serialized refresh and the provider is a plain Keychain
/// read. Implementations must also never block the calling thread (no
/// semaphore waits, no synchronous I/O) — suspend with `await` instead.
public typealias OAuthTokenProvider = @Sendable () async throws -> String

/// Provides the current refresh token from the Keychain. Called by
/// Transport before issuing a `grant_type=refresh_token` POST. Never
/// called concurrently — the Transport actor serializes access. Never
/// log the returned value (NFR-S2).
public typealias OAuthRefreshProvider = @Sendable () async throws -> String

/// Receives a fresh token pair after a successful silent refresh.
/// The app implementation calls `KeychainStore.saveOAuthTokens(...)`.
/// Always called from within the Transport actor's serialized refresh
/// task — never concurrently. Never log any field of `OAuthTokenResponse`
/// (NFR-S2).
///
/// A throw from this closure is permanently destructive: by the time it
/// is called, the single-use refresh token has already been consumed at
/// the token endpoint, so throwing discards the rotated pair and burns
/// the token family — the Keychain keeps the stale refresh token, the
/// next refresh replays it, the server revokes the family, and the user
/// must re-authenticate. The SDK attempts no recovery. Implementations
/// must therefore be robust, throw only when persistence genuinely
/// failed, and throw `ComfyError.unknown(underlying:)` — never
/// `.authInvalid` — for infrastructure failures such as a Keychain
/// write error, so a storage problem is not misreported to the user as
/// auth expiry.
public typealias OAuthTokenStore = @Sendable (OAuthTokenResponse) async throws -> Void

/// Returns the stored access-token expiry `Date`, or `nil` if not yet
/// stored. Called synchronously by Transport for proactive refresh
/// checks — must not block. `nil` is treated as "already expired"
/// (triggers proactive refresh).
public typealias OAuthExpiryProvider = @Sendable () throws -> Date?

/// Credential mode for `ComfyCloudClient`. Modes during coexistence:
/// `.apiKey` for legacy users, `.oauth` for callers that manage token
/// refresh externally (and for tests), and `.oauthRefreshable` — the
/// production OAuth case for Story 8.5+ callers, where the SDK owns
/// proactive and 401-triggered serialized refresh.
///
/// Transport encoding note: HTTP requests carry the credential in a
/// header (`X-API-Key: <key>` or `Authorization: Bearer <token>`), but
/// the Comfy Cloud WebSocket endpoint does not accept custom headers,
/// so on the WebSocket leg the credential travels as a `?token=` URL
/// query parameter instead, in every mode.
public enum ComfyCredential: Sendable {
    /// Legacy API-key mode. Injects `X-API-Key: <key>` on HTTP requests.
    case apiKey(String)
    /// OAuth Bearer mode. Calls `tokenProvider` to obtain a current access
    /// token for each request; injects `Authorization: Bearer <token>`.
    /// The provider is responsible for token freshness — if the token is
    /// expired and cannot be refreshed, the provider should throw and the
    /// SDK surfaces `ComfyError.authInvalid`. For SDK-owned silent
    /// refresh, use `oauthRefreshable` instead (Story 8.5).
    case oauth(tokenProvider: OAuthTokenProvider)
    /// OAuth Bearer mode with SDK-managed serialized refresh (Story 8.5).
    /// Use this case for production sign-in flows where the SDK should
    /// silently refresh the access token before expiry and on 401, using
    /// the single-use refresh token without risking family revocation.
    ///
    /// Transport encoding: same as `.oauth` — Bearer JWT on HTTP,
    /// `?token=<jwt>` on WebSocket.
    ///
    /// Story 8.5.
    case oauthRefreshable(
        tokenProvider: OAuthTokenProvider,
        refreshProvider: OAuthRefreshProvider,
        tokenStore: OAuthTokenStore,
        expiryProvider: OAuthExpiryProvider
    )
}
