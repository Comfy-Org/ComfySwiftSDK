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

    @Test("redirect URI matches the pending backend seed byte-identically")
    func redirectURIMatchesContract() {
        #expect(OAuthConfiguration.redirectURI == "org.comfy.ios://oauth-callback")
    }

    @Test("callback scheme is org.comfy.ios")
    func callbackSchemeMatchesContract() {
        #expect(OAuthConfiguration.callbackScheme == "org.comfy.ios")
    }

    @Test("client ID is comfy-ios")
    func clientIdMatchesContract() {
        #expect(OAuthConfiguration.clientId == "comfy-ios")
    }

    @Test("redirect URI scheme contains a dot — bare comfy:// is denylisted")
    func redirectURISchemeContainsDot() throws {
        let scheme = try #require(
            OAuthConfiguration.redirectURI.split(separator: ":").first.map(String.init)
        )
        #expect(scheme.contains("."))
    }

    @Test("redirect URI starts with callbackScheme + ://")
    func redirectURIStartsWithCallbackScheme() {
        #expect(
            OAuthConfiguration.redirectURI.hasPrefix(OAuthConfiguration.callbackScheme + "://")
        )
    }
}
