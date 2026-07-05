import Foundation

/// One PKCE authorization attempt's material: the authorize URL to present, the `state` nonce to verify on callback, and the code verifier to redeem at the token endpoint.
public struct OAuthAuthorizationRequest: Sendable {

    /// The fully-formed authorize URL to present in the web authentication session.
    public let authorizationURL: URL

    /// The random CSRF nonce to verify against the callback's `state`. Treat as a short-lived secret.
    public let state: String

    /// The PKCE verifier to hand back to `ComfyCloudClient.exchangeAuthorizationCode(_:codeVerifier:config:)`. Treat as a secret.
    public let codeVerifier: String

    /// The ``OAuthClientConfig`` this request was built with.
    ///
    /// Carried on the request so the redemption step can reuse the exact config that produced the
    /// authorize URL — pass it straight through to
    /// ``ComfyCloudClient/exchangeAuthorizationCode(_:codeVerifier:config:)`` (and to the
    /// ``ComfyCloudClient`` used for refresh) rather than re-specifying it and risking a
    /// `client_id` / `redirect_uri` mismatch that only surfaces as a server-rejected exchange.
    public let config: OAuthClientConfig

    /// Validates an OAuth callback URL against this request and extracts the authorization code.
    ///
    /// Performs the security-critical callback check: it reads the `code` and `state` query
    /// items, rejects a missing or empty `code`, and — the CSRF defense — requires the callback's
    /// `state` to equal this request's ``state``. Only then is the code returned for redemption
    /// with ``ComfyCloudClient/exchangeAuthorizationCode(_:codeVerifier:config:)``.
    ///
    /// - Parameter url: The callback URL delivered to the app's OAuth redirect scheme.
    /// - Returns: The non-empty authorization `code` from the callback.
    /// - Throws: ``ComfyError/authCancelled`` if the callback carries no non-empty `code`, i.e. the
    ///   authorization did not complete; ``ComfyError/authStateMismatch`` if the callback has a
    ///   code but its `state` is absent or does not match this request's ``state`` — a present code
    ///   we cannot state-verify is a CSRF/misconfiguration signal, not a user cancellation.
    public func extractCode(fromCallback url: URL) throws -> String {
        // A bare `code=` query item yields "" (not nil) from URLQueryItem.value — reject it here
        // rather than letting the token endpoint 400 on it.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw ComfyError.authCancelled
        }
        // A code arrived but we can't verify it came from our request: a missing `state` is as much
        // a CSRF/misconfiguration signal as a mismatched one, so both fail closed the same way and
        // the code is never redeemed.
        guard let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state
        else {
            throw ComfyError.authStateMismatch
        }
        return code
    }
}
