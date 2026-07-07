import Foundation

/// The browser step of the interactive OAuth sign-in, injected into
/// ``ComfyAuth/signIn(presenter:store:config:)`` so the SDK never imports
/// `AuthenticationServices`.
///
/// The SDK owns the whole authorization-code + PKCE handshake *except* actually presenting the
/// authorize URL to the user — that requires `ASWebAuthenticationSession` (UIKit/AppKit surface),
/// which the SDK deliberately keeps out of its import boundary (Foundation only). An app conforms a
/// thin type to this protocol over its own `ASWebAuthenticationSession`, and hands it to
/// ``ComfyAuth/signIn(presenter:store:config:)``.
///
/// A conformer opens a web authentication session for `url`, waits for the callback delivered to
/// `callbackURLScheme`, and returns that callback URL unchanged. The SDK then performs the
/// security-critical `state` verification and code extraction itself
/// (``OAuthAuthorizationRequest/extractCode(fromCallback:)``) — a conformer must **not** parse the
/// callback or short-circuit that check.
///
/// - Important: On user dismissal (the person taps *Cancel* / closes the sheet), a conformer must
///   throw ``ComfyError/authCancelled`` — the same case the SDK propagates from
///   ``ComfyAuth/signIn(presenter:store:config:)``, so callers distinguish "the user backed out"
///   from a genuine failure by catching a single, stable error type. Any other transport-level
///   error may be thrown as-is.
public protocol ComfyWebAuthPresenter: Sendable {

    /// Presents `url` in a web authentication session and returns the callback URL the OAuth server
    /// redirects to.
    ///
    /// - Parameters:
    ///   - url: The authorize URL to present, from
    ///     ``OAuthAuthorizationRequest/authorizationURL``.
    ///   - callbackURLScheme: The custom URL scheme the callback is delivered to, from
    ///     ``OAuthClientConfig/redirectScheme`` — hand this straight to
    ///     `ASWebAuthenticationSession`'s `callbackURLScheme`.
    /// - Returns: The callback URL delivered to `callbackURLScheme`, returned unchanged for the SDK
    ///   to validate.
    /// - Throws: ``ComfyError/authCancelled`` when the user dismisses the session; any other error
    ///   on a transport-level failure.
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL
}
