import Foundation

/// One PKCE authorization attempt's material: the authorize URL to present, the `state` nonce to verify on callback, and the code verifier to redeem at the token endpoint.
public struct OAuthAuthorizationRequest: Sendable {

    /// The fully-formed authorize URL to present in the web authentication session.
    public let authorizationURL: URL

    /// The random CSRF nonce to verify against the callback's `state`. Treat as a short-lived secret.
    public let state: String

    /// The PKCE verifier to hand back to `ComfyCloudClient.exchangeAuthorizationCode(_:codeVerifier:config:)`. Treat as a secret.
    public let codeVerifier: String

    /// Validates an OAuth callback URL against this request and extracts the authorization code.
    ///
    /// Performs the security-critical callback check: it reads the `code` and `state` query
    /// items, rejects a missing or empty `code`, and — the CSRF defense — requires the callback's
    /// `state` to equal this request's ``state``. Only then is the code returned for redemption
    /// with ``ComfyCloudClient/exchangeAuthorizationCode(_:codeVerifier:config:)``.
    ///
    /// - Parameter url: The callback URL delivered to the app's OAuth redirect scheme.
    /// - Returns: The non-empty authorization `code` from the callback.
    /// - Throws: ``ComfyError/authStateMismatch`` if the callback's `state` does not match this
    ///   request's ``state``; ``ComfyError/authCancelled`` if the callback carries no non-empty
    ///   `code` (or no `state` at all), i.e. the authorization did not complete.
    public func extractCode(fromCallback url: URL) throws -> String {
        // A bare `code=` query item yields "" (not nil) from URLQueryItem.value — reject it here
        // rather than letting the token endpoint 400 on it.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty,
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            throw ComfyError.authCancelled
        }
        guard returnedState == state else {
            throw ComfyError.authStateMismatch
        }
        return code
    }
}
