import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("OAuthConfiguration — AC1")
struct OAuthConfigurationTests {

    @Test("issuer resolves to https://cloud.comfy.org")
    func issuerMatchesContract() {
        #expect(OAuthConfiguration.issuer.absoluteString == "https://cloud.comfy.org")
    }

    @Test("authorization endpoint is issuer + /oauth/authorize")
    func authorizationEndpointMatchesContract() {
        #expect(
            OAuthConfiguration.authorizationEndpoint.absoluteString
                == "https://cloud.comfy.org/oauth/authorize"
        )
    }

    @Test("token endpoint is issuer + /oauth/token")
    func tokenEndpointMatchesContract() {
        #expect(
            OAuthConfiguration.tokenEndpoint.absoluteString
                == "https://cloud.comfy.org/oauth/token"
        )
    }

    @Test("metadata URL is issuer + /.well-known/oauth-authorization-server (RFC 8414, confirmed live 2026-06-09)")
    func metadataURLMatchesContract() {
        #expect(
            OAuthConfiguration.metadataURL.absoluteString
                == "https://cloud.comfy.org/.well-known/oauth-authorization-server"
        )
    }

    @Test("PKCE code-challenge method is S256")
    func pkceMethodIsS256() {
        #expect(OAuthConfiguration.pkceCodeChallengeMethod == "S256")
    }

    @Test("public client: token_endpoint_auth_method is none")
    func tokenEndpointAuthMethodIsNone() {
        #expect(OAuthConfiguration.tokenEndpointAuthMethod == "none")
    }

    @Test("RFC 8707 resource parameter is https://cloud.comfy.org/api")
    func resourceParameterMatchesContract() {
        #expect(OAuthConfiguration.resourceParameter == "https://cloud.comfy.org/api")
    }

    // The per-app client id / redirect URI / redirect scheme / scopes moved to the public
    // OAuthClientConfig; their contract assertions now live in OAuthClientConfigTests.
}
