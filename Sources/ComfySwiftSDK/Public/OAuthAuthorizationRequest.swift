import Foundation

/// One PKCE authorization attempt's material: the authorize URL to present, the `state` nonce to verify on callback, and the code verifier to redeem at the token endpoint.
public struct OAuthAuthorizationRequest: Sendable {

    /// The fully-formed authorize URL to present in the web authentication session.
    public let authorizationURL: URL

    /// The random CSRF nonce to verify against the callback's `state`. Treat as a short-lived secret.
    public let state: String

    /// The PKCE verifier to hand back to `ComfyCloudClient.exchangeAuthorizationCode(_:codeVerifier:)`. Treat as a secret.
    public let codeVerifier: String
}
