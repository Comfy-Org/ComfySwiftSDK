//
//  OAuthTokenResponse.swift
//  ComfySwiftSDK
//
//  The decoded result of a successful code→token exchange at
//  `/oauth/token` (Story 8.3, AC2). Returned by
//  `ComfyCloudClient.exchangeAuthorizationCode(_:codeVerifier:)` for
//  the app to persist in the Keychain (Story 8.4's job — the SDK never
//  stores tokens).
//
//  Story 8.3.
//

import Foundation

/// Access + refresh token pair from the token endpoint.
///
/// Privacy contract (NFR-S2): both `accessToken` and `refreshToken`
/// are secrets — never log either fragment in any form, never embed
/// them in error messages, never expose them outside the Keychain
/// write path.
public struct OAuthTokenResponse: Sendable {

    /// The Bearer access token attached to API requests — **never log**
    /// (NFR-S2).
    public let accessToken: String

    /// The refresh token redeemed for new access tokens — **never log**
    /// (NFR-S2).
    public let refreshToken: String

    /// Seconds until the access token expires (typical: 900 = 15 min).
    public let expiresIn: Int
}
