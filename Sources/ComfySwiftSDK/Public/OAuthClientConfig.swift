import Foundation

/// The per-app OAuth client parameters the SDK's authorization primitives are keyed on.
///
/// These are the values that differ between apps that embed the SDK — the registered
/// `clientId`, the custom URL scheme the app owns, its full redirect URI, and the scopes it
/// requests. The shared protocol endpoints (issuer, authorize, token, and metadata URLs) are
/// not part of this config; they live in the SDK and are the same for every app.
///
/// Pass a value to ``ComfyCloudClient/buildAuthorizationRequest(config:)`` and
/// ``ComfyCloudClient/exchangeAuthorizationCode(_:codeVerifier:config:)``. Apps that don't
/// need to customize anything can rely on the default, ``comfyIOS``.
public struct OAuthClientConfig: Sendable {

    /// The OAuth `client_id` registered for this app.
    public let clientId: String

    /// The custom URL scheme this app owns for its OAuth callback (e.g. `org.comfy.ios`).
    ///
    /// This is the scheme half of ``redirectURI`` — the value an app registers under
    /// `CFBundleURLSchemes` and hands to `ASWebAuthenticationSession` as its
    /// `callbackURLScheme`.
    public let redirectScheme: String

    /// The full OAuth `redirect_uri` for this app (e.g. `org.comfy.ios://oauth-callback`).
    public let redirectURI: String

    /// The OAuth scopes this app requests, one element per scope.
    ///
    /// Joined with a single space to form the `scope` request parameter.
    public let scopes: [String]

    /// Creates an OAuth client configuration.
    ///
    /// `redirectURI`'s scheme must equal `redirectScheme`: the SDK sends `redirectURI` to the
    /// authorization server while the app registers `redirectScheme` with
    /// `ASWebAuthenticationSession`, so a mismatched pair delivers the callback to a scheme the
    /// app never observes and the sign-in silently stalls. This is enforced with a
    /// `precondition`, as both are compile-time constants the embedding app controls.
    ///
    /// - Parameters:
    ///   - clientId: The registered OAuth `client_id`.
    ///   - redirectScheme: The custom URL scheme this app owns for its callback.
    ///   - redirectURI: The full redirect URI (its scheme must be `redirectScheme`).
    ///   - scopes: The OAuth scopes to request, one element per scope.
    public init(
        clientId: String,
        redirectScheme: String,
        redirectURI: String,
        scopes: [String]
    ) {
        precondition(
            URL(string: redirectURI)?.scheme?.caseInsensitiveCompare(redirectScheme) == .orderedSame,
            "OAuthClientConfig.redirectURI scheme must equal redirectScheme "
                + "(got redirectURI=\"\(redirectURI)\", redirectScheme=\"\(redirectScheme)\")"
        )
        self.clientId = clientId
        self.redirectScheme = redirectScheme
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// The configuration for the first-party Comfy iOS app.
    ///
    /// This is the default for the SDK's authorization helpers, and carries the exact values
    /// the SDK shipped with before the config was parameterized, so existing call sites are
    /// unaffected.
    public static let comfyIOS = OAuthClientConfig(
        clientId: "comfy-ios",
        redirectScheme: "org.comfy.ios",
        redirectURI: "org.comfy.ios://oauth-callback",
        scopes: [
            "comfy-cloud:workflows:read", "comfy-cloud:workflows:write",
            "comfy-cloud:jobs:read", "comfy-cloud:jobs:write",
            "comfy-cloud:files:read", "comfy-cloud:files:write",
        ]
    )
}
