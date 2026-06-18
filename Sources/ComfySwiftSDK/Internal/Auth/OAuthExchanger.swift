//
//  OAuthExchanger.swift
//  ComfySwiftSDK
//
//  Performs the PKCE code→token exchange at
//  `OAuthConfiguration.tokenEndpoint` (AC2, Story 8.3). The request is
//  a `application/x-www-form-urlencoded` POST carrying the
//  authorization code, the per-attempt `code_verifier`, the seeded
//  public-client id, and the mandatory RFC 8707 `resource` parameter —
//  and deliberately NO client secret (`token_endpoint_auth_method=none`).
//
//  Error mapping follows the Transport.swift translation table
//  (`Transport.translate(_:)` and `Transport.checkStatus(_:)` are
//  reused directly so the paths can never drift — same pattern as
//  `OAuthMetadataFetcher`):
//    - HTTP 401/403 → .authInvalid, 429 → .rateLimited, other
//      non-2xx → .network(underlying:) (Transport.checkStatus)
//    - URLError → .offline/.timeout/.cancelled/.network (Transport.translate)
//    - DecodingError → .unknown(underlying:) — a malformed token
//      response is unrecoverable by the app
//
//  Logging in this file: NONE — and load-bearing this time, not just
//  policy: `code`, `codeVerifier`, `accessToken`, and `refreshToken`
//  all pass through here and none may ever touch `Log.*` (NFR-S2).
//
//  Story 8.3.
//

import Foundation

/// Exchanges an authorization code (plus its PKCE verifier) for a
/// token pair at the token endpoint. Owns nothing but a `URLSession` —
/// presenting the web session and verifying `state` are the app's job
/// (NFR-M2 carve-out); storing the tokens is Story 8.4's.
internal actor OAuthExchanger {

    /// Decoded shape of the token-endpoint success response. Private —
    /// callers only ever see the public `OAuthTokenResponse` mapping.
    private struct TokenExchangeDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
            case tokenType    = "token_type"
        }
    }

    // `nonisolated`: set once in init and never mutated — no actor hop
    // needed to read it (same rationale as OAuthMetadataFetcher).
    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    /// POST the code→token exchange and return the decoded token pair.
    /// Throws `ComfyError` on any failure (never `URLError`, never
    /// `DecodingError` raw).
    internal func exchange(code: String, codeVerifier: String) async throws -> OAuthTokenResponse {
        // URLComponents.query performs the percent-encoding for every
        // value (the RFC 8707 resource URL in particular must arrive
        // as https%3A%2F%2Fcloud.comfy.org%2Fapi). No client_secret:
        // public client, token_endpoint_auth_method=none.
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type",    value: "authorization_code"),
            URLQueryItem(name: "code",          value: code),
            URLQueryItem(name: "redirect_uri",  value: OAuthConfiguration.redirectURI),
            URLQueryItem(name: "client_id",     value: OAuthConfiguration.clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Transport.translate(error)
        }

        // Resolve HTTP error statuses before decoding — otherwise an
        // error-response body fails the JSON decode and the real cause
        // (401/429/5xx) is masked behind .unknown (same ordering as
        // OAuthMetadataFetcher).
        try Transport.checkStatus(response)

        let dto: TokenExchangeDTO
        do {
            dto = try JSONDecoder().decode(TokenExchangeDTO.self, from: data)
        } catch {
            // A malformed token response is unrecoverable by the app —
            // either a programmer error or an unexpected backend change.
            throw ComfyError.unknown(underlying: error)
        }

        return OAuthTokenResponse(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresIn: dto.expiresIn
        )
    }
}
