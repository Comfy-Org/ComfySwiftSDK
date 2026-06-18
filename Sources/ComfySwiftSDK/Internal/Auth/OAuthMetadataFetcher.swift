//
//  OAuthMetadataFetcher.swift
//  ComfySwiftSDK
//
//  Fetches and validates the authorization-server metadata document
//  from the Comfy Cloud issuer (AC2, Story 8.1). Validation is strict:
//  a parsed `issuer`, `authorization_endpoint`, or `token_endpoint`
//  that does not byte-match the corresponding `OAuthConfiguration`
//  constant, or a `code_challenge_methods_supported` list missing
//  `S256`, all throw `.authInvalid` — the server is not the
//  authorization server this SDK was built against, so no PKCE flow
//  may proceed.
//
//  Error mapping follows the Transport.swift translation table
//  (`Transport.translate(_:)` and `Transport.checkStatus(_:)` are
//  reused directly so the two paths can never drift):
//    - HTTP 401/403 → .authInvalid, 429 → .rateLimited, other
//      non-2xx → .network(underlying:) (Transport.checkStatus)
//    - URLError.notConnectedToInternet/.networkConnectionLost/
//      .dataNotAllowed → .offline
//    - other URLError → .network(underlying:) (plus the canonical
//      .timedOut → .timeout and .cancelled → .cancelled cases)
//    - DecodingError → .unknown(underlying:) — malformed metadata is
//      unrecoverable by the app (programmer error or unexpected
//      backend change)
//
//  Logging in this file: NONE — consistent with the Transport.swift
//  policy (SDK observability deferred; OAuth credential-logging
//  enforcement lands in Story 8.8).
//
//  Story 8.1.
//

import Foundation

/// Fetches the AS metadata document from
/// `OAuthConfiguration.metadataURL` and validates it against the
/// compiled-in contract. Owns nothing but a `URLSession` — token
/// handling, PKCE, and the web-auth session live in later Epic 8
/// stories.
internal actor OAuthMetadataFetcher {

    /// Decoded shape of the AS metadata document (RFC 8414 / OIDC
    /// discovery). Internal rather than private because
    /// `fetchAndValidate()` returns it (Swift forbids an internal
    /// method returning a private type) and the Story 8.1 unit tests
    /// assert on the parsed fields via `@testable import`.
    internal struct OAuthServerMetadata: Codable, Sendable {
        let issuer: String
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    // `nonisolated`: set once in init and never mutated — no actor hop
    // needed to read it (review L2).
    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    /// Fetch `OAuthConfiguration.metadataURL`, decode it, and validate
    /// the issuer, both endpoints, and S256 support. Returns the
    /// validated metadata on success; throws `ComfyError` on any
    /// failure (never `URLError`, never `DecodingError` raw).
    internal func fetchAndValidate() async throws -> OAuthServerMetadata {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: URLRequest(url: OAuthConfiguration.metadataURL))
        } catch {
            throw Transport.translate(error)
        }

        // Resolve HTTP error statuses before decoding — otherwise an
        // error-response body fails the JSON decode and the real cause
        // (401/429/5xx) is masked behind .unknown (review H1).
        try Transport.checkStatus(response)

        let metadata: OAuthServerMetadata
        do {
            metadata = try JSONDecoder().decode(OAuthServerMetadata.self, from: data)
        } catch {
            // Malformed metadata is unrecoverable by the app — either a
            // programmer error or an unexpected backend change.
            throw ComfyError.unknown(underlying: error)
        }

        // The authorization server is not the one this SDK was built
        // against — treat as auth invalid. Exact byte match per
        // RFC 8414 §3, deliberately with no trailing-slash tolerance:
        // the live value is pinned by the RUN_OAUTH_INTEGRATION
        // integration test, and a backend canonicalization change
        // (e.g. "https://cloud.comfy.org/") must fail loudly here
        // rather than be papered over (review M1).
        guard metadata.issuer == OAuthConfiguration.issuer.absoluteString else {
            throw ComfyError.authInvalid
        }

        // The endpoints the flow will actually hit must byte-match the
        // compiled-in contract too — an issuer-matching document that
        // serves attacker-controlled endpoint URLs must not survive
        // validation (review H2; Story 8.3 builds the authorize request
        // from these values).
        guard metadata.authorizationEndpoint == OAuthConfiguration.authorizationEndpoint.absoluteString,
              metadata.tokenEndpoint == OAuthConfiguration.tokenEndpoint.absoluteString else {
            throw ComfyError.authInvalid
        }

        // No S256 → the PKCE S256 flow cannot be performed with this
        // server — auth invalid.
        guard let methods = metadata.codeChallengeMethodsSupported,
              methods.contains(OAuthConfiguration.pkceCodeChallengeMethod) else {
            throw ComfyError.authInvalid
        }

        return metadata
    }
}
