import Foundation

/// Access + refresh token pair from the token endpoint. Both tokens are secrets and must never be logged.
public struct OAuthTokenResponse: Sendable {

    /// The Bearer access token attached to API requests. Treat as a secret.
    public let accessToken: String

    /// The refresh token redeemed for new access tokens. Treat as a secret.
    public let refreshToken: String

    /// Seconds until the access token expires.
    public let expiresIn: Int
}
