//
//  OAuthTokenRefreshExecutor.swift
//  ComfySwiftSDK
//
//  Issues the `grant_type=refresh_token` POST to
//  `OAuthConfiguration.tokenEndpoint` (AC8, Story 8.5). Reuses
//  `Transport.translate(_:)` and `Transport.checkStatus(_:)` for error
//  mapping — same approach as `OAuthExchanger`, no divergence. The
//  request is `application/x-www-form-urlencoded`, carries the
//  single-use refresh token, the seeded public-client id, and the
//  mandatory RFC 8707 `resource` parameter — and deliberately NO
//  client secret (`token_endpoint_auth_method=none`).
//
//  Key difference from `OAuthExchanger`: a 401 on the REFRESH endpoint
//  means the refresh token itself was rejected — the family is revoked
//  or the token exhausted — so it maps to `.authExpired` (re-sign-in
//  required), not `.authInvalid` (wrong credential on a normal endpoint).
//
//  Callers MUST serialize calls into this actor per refresh window:
//  Comfy Cloud refresh tokens are single-use with family-revoke-on-reuse,
//  so two concurrent POSTs with the same refresh token permanently lock
//  the user out. `Transport.performRefresh` owns that serialization via
//  its coalescing `pendingRefreshTask`.
//
//  Logging in this file: NONE — and load-bearing, not just policy:
//  `refreshToken` and both output token fragments are secrets and none
//  may ever touch `Log.*` in any code path (NFR-S2).
//
//  Story 8.5.
//

import Foundation

/// Redeems a single-use refresh token for a rotated token pair at the
/// token endpoint. Owns nothing but a `URLSession` — reading the
/// refresh token from the Keychain and persisting the rotated pair are
/// the app's job, mediated by the `oauthRefreshable` closures.
internal actor OAuthTokenRefreshExecutor {

    /// Decoded shape of the token-endpoint refresh response. Private —
    /// callers only ever see the public `OAuthTokenResponse` mapping.
    private struct TokenRefreshDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    // `nonisolated`: set once in init and never mutated — no actor hop
    // needed to read it (same rationale as OAuthExchanger).
    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    /// POST the refresh-token grant and return the rotated token pair.
    /// Throws `ComfyError` on any failure (never `URLError`, never
    /// `DecodingError` raw). A 401/403 here surfaces as `.authExpired`
    /// — the refresh token family is revoked or exhausted.
    internal func refresh(using refreshToken: String) async throws -> OAuthTokenResponse {
        // URLComponents.query performs the percent-encoding for every
        // value (the RFC 8707 resource URL in particular must arrive
        // as https%3A%2F%2Fcloud.comfy.org%2Fapi). No client_secret:
        // public client, token_endpoint_auth_method=none.
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type",    value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id",     value: OAuthConfiguration.clientId),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // `URLComponents.query` is effectively infallible for these
        // values, but a silent nil here would fire a body-less POST and
        // mask the real cause behind the server's 400 → `.network`
        // (review 8-5, LOW). Fail loudly instead.
        guard let bodyString = body.query, let bodyData = bodyString.data(using: .utf8) else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        request.httpBody = bodyData

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
        // OAuthExchanger). Unique to the refresh path: intercept
        // `.authInvalid` and re-throw as `.authExpired` — a 401 on a
        // refresh request means the refresh token itself was rejected
        // (family revoked), not that the wrong credential was presented
        // to a normal endpoint.
        do {
            try Transport.checkStatus(response)
        } catch ComfyError.authInvalid {
            throw ComfyError.authExpired   // 401 on refresh → token family exhausted
        }

        let dto: TokenRefreshDTO
        do {
            dto = try JSONDecoder().decode(TokenRefreshDTO.self, from: data)
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
