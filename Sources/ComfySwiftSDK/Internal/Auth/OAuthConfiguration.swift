import Foundation

internal enum OAuthConfiguration {

    static let issuer: URL = URL(string: "https://cloud.comfy.org")!

    static let authorizationEndpoint: URL = issuer.appendingPathComponent("oauth/authorize")

    static let tokenEndpoint: URL = issuer.appendingPathComponent("oauth/token")

    static let metadataURL: URL = issuer.appendingPathComponent(".well-known/oauth-authorization-server")

    static let pkceCodeChallengeMethod: String = "S256"

    static let tokenEndpointAuthMethod: String = "none"

    static let resourceParameter: String = "https://cloud.comfy.org/api"

    static let scope: String = [
        "comfy-cloud:workflows:read", "comfy-cloud:workflows:write",
        "comfy-cloud:jobs:read", "comfy-cloud:jobs:write",
        "comfy-cloud:files:read", "comfy-cloud:files:write",
    ].joined(separator: " ")

    static let redirectURI: String = "org.comfy.ios://oauth-callback"

    static let callbackScheme: String = "org.comfy.ios"

    static let clientId: String = "comfy-ios"
}
