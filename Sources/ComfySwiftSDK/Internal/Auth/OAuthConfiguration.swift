import Foundation

/// The OAuth protocol endpoints and constants shared by every app that embeds the SDK.
///
/// Per-app values (client id, redirect URI/scheme, scopes) are not here — they live in the
/// public ``OAuthClientConfig`` and are passed to the authorization helpers.
internal enum OAuthConfiguration {

    static let issuer: URL = URL(string: "https://cloud.comfy.org")!

    static let authorizationEndpoint: URL = issuer.appendingPathComponent("oauth/authorize")

    static let tokenEndpoint: URL = issuer.appendingPathComponent("oauth/token")

    static let metadataURL: URL = issuer.appendingPathComponent(".well-known/oauth-authorization-server")

    static let pkceCodeChallengeMethod: String = "S256"

    static let tokenEndpointAuthMethod: String = "none"

    static let resourceParameter: String = "https://cloud.comfy.org/api"
}
