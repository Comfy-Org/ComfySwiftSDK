//
//  OAuthConfiguration.swift
//  ComfySwiftSDK
//
//  The single authoritative OAuth configuration for the Comfy Cloud
//  authorization server. Every later Epic 8 story (PKCE flow, token
//  refresh, bearer injection) reads its endpoints and parameters from
//  here — no other file in the SDK may hard-code an OAuth endpoint,
//  scheme, or parameter value (FR-OAuth-1).
//
//  Contract source: sprint-change-proposal-2026-06-09.md §1 / §4.7.
//    - Issuer: https://cloud.comfy.org
//    - Endpoints confirmed in backend source: /oauth/authorize +
//      /oauth/token (oauth_metadata.go:48-52)
//    - Grant: authorization-code + PKCE S256 (pkce.go:25-37)
//    - Public client: token_endpoint_auth_method=none — no client
//      secret ships on-device
//    - RFC 8707 resource parameter: https://cloud.comfy.org/api —
//      MANDATORY on both the authorize and token requests
//    - Redirect scheme: custom reverse-DNS org.comfy.ios://oauth-callback
//      (redirect_policy.go:116-136)
//
//  Logging in this file: NONE — consistent with the Transport.swift
//  policy (SDK observability deferred).
//
//  Story 8.1.
//

import Foundation

/// Namespace for the Comfy Cloud OAuth contract constants. Deliberately
/// an `enum` (no cases) so it can never be instantiated — every member
/// is a `static let`. Internal: the public SDK surface grows in
/// Story 8.2; nothing here is exposed to the app target.
internal enum OAuthConfiguration {

    /// The authorization server's issuer identifier. AS metadata whose
    /// `issuer` field does not match this string byte-for-byte is
    /// rejected (`OAuthMetadataFetcher`).
    static let issuer: URL = URL(string: "https://cloud.comfy.org")!

    /// `GET /oauth/authorize` — the authorization endpoint
    /// (oauth_metadata.go:48-52).
    static let authorizationEndpoint: URL = issuer.appendingPathComponent("oauth/authorize")

    /// `POST /oauth/token` — the token endpoint (oauth_metadata.go:48-52).
    static let tokenEndpoint: URL = issuer.appendingPathComponent("oauth/token")

    /// AS metadata discovery document. Confirmed live 2026-06-09: the
    /// backend serves the RFC 8414 canonical path below (HTTP 200 with
    /// matching issuer/endpoints/S256); the OIDC-style
    /// `/.well-known/openid-configuration` returns 404. This constant
    /// is the single source of truth, so any future path change is a
    /// one-line edit (Story 8.1 Dev Notes "AS metadata discovery path").
    static let metadataURL: URL = issuer.appendingPathComponent(".well-known/oauth-authorization-server")

    /// PKCE code-challenge method. The backend supports S256 only
    /// (pkce.go:25-37); `plain` is never sent.
    static let pkceCodeChallengeMethod: String = "S256"

    /// Public-client token endpoint auth method — no client secret is
    /// ever embedded in the app binary.
    static let tokenEndpointAuthMethod: String = "none"

    /// RFC 8707 resource indicator. MANDATORY on both the authorize and
    /// token requests — omitting it yields tokens with the wrong
    /// audience that the generation routes reject.
    static let resourceParameter: String = "https://cloud.comfy.org/api"

    /// Requested scopes, space-separated (RFC 6749 §3.3). The server
    /// requires a non-empty `scope` on authorize — it deliberately
    /// tightens RFC 6749's optional scope to required (request.go:47-53,
    /// ErrEmptyScope) — so omitting this parameter fails parse with
    /// `invalid_request` before the client is even looked up. The set
    /// below is the app's functional surface per the 8.1 gate request
    /// (generation + upload/view); it must stay a subset of the seeded
    /// `comfy-ios` grant. Requesting MORE scopes later triggers a
    /// consent re-grant (server-side ErrScopeBroadening path), which is
    /// handled UX — just expect the consent sheet to reappear.
    static let scope: String = [
        "comfy-cloud:workflows:read", "comfy-cloud:workflows:write",
        "comfy-cloud:jobs:read", "comfy-cloud:jobs:write",
        "comfy-cloud:files:read", "comfy-cloud:files:write",
    ].joined(separator: " ")

    /// The registered redirect URI for the seeded `comfy-ios` client.
    // Pending byte-identical backend seed. Bare comfy:// is denylisted;
    // scheme must contain a dot (redirect_policy.go:116-136).
    static let redirectURI: String = "org.comfy.ios://oauth-callback"

    /// The scheme portion of `redirectURI` — handed to
    /// `ASWebAuthenticationSession(callbackURLScheme:)` by the app
    /// target in Story 8.3 (NFR-M2 carve-out: the session itself never
    /// lives in the SDK).
    static let callbackScheme: String = "org.comfy.ios"

    /// The registered OAuth client identifier for this app.
    // Seeded by the cloud team; mirrors Desktop/CLI operator pattern
    // (sprint-change-proposal-2026-06-09.md §1).
    static let clientId: String = "comfy-ios"
}
