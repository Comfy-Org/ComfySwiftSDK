import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("OAuthClientConfig — parameterized client config + callback state verification")
struct OAuthClientConfigTests {

    private func queryItems(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    // MARK: - Back-compat: comfyIOS carries the prior hardcoded values byte-identically

    @Test("comfyIOS default matches the prior hardcoded client id / redirect / scheme")
    func comfyIOSDefaultMatchesPriorConstants() {
        let config = OAuthClientConfig.comfyIOS
        #expect(config.clientId == "comfy-ios")
        #expect(config.redirectScheme == "org.comfy.ios")
        #expect(config.redirectURI == "org.comfy.ios://oauth-callback")
    }

    @Test("comfyIOS scopes match the prior hardcoded scope list, in order")
    func comfyIOSScopesMatchPriorList() {
        #expect(OAuthClientConfig.comfyIOS.scopes == [
            "comfy-cloud:workflows:read", "comfy-cloud:workflows:write",
            "comfy-cloud:jobs:read", "comfy-cloud:jobs:write",
            "comfy-cloud:files:read", "comfy-cloud:files:write",
        ])
    }

    @Test("comfyIOS scopes join to the exact prior space-separated scope string")
    func comfyIOSScopesJoinToPriorScopeString() {
        #expect(
            OAuthClientConfig.comfyIOS.scopes.joined(separator: " ")
                == "comfy-cloud:workflows:read comfy-cloud:workflows:write"
                + " comfy-cloud:jobs:read comfy-cloud:jobs:write"
                + " comfy-cloud:files:read comfy-cloud:files:write"
        )
    }

    @Test("comfyIOS redirect URI is scheme + :// (bare comfy:// denylisted, scheme has a dot)")
    func comfyIOSRedirectURIWellFormed() throws {
        let config = OAuthClientConfig.comfyIOS
        #expect(config.redirectURI.hasPrefix(config.redirectScheme + "://"))
        let scheme = try #require(config.redirectURI.split(separator: ":").first.map(String.init))
        #expect(scheme.contains("."))
    }

    @Test("oauthCallbackScheme static stays the comfyIOS redirect scheme")
    func oauthCallbackSchemeIsComfyIOSDefault() {
        #expect(ComfyCloudClient.oauthCallbackScheme == OAuthClientConfig.comfyIOS.redirectScheme)
        #expect(ComfyCloudClient.oauthCallbackScheme == "org.comfy.ios")
    }

    // MARK: - Injected config flows into the authorize URL

    @Test("buildAuthorizationRequest(config:) injects client_id, redirect_uri, and scopes")
    func injectedConfigFlowsIntoAuthorizeURL() {
        let custom = OAuthClientConfig(
            clientId: "acme-app",
            redirectScheme: "com.acme.app",
            redirectURI: "com.acme.app://oauth-callback",
            scopes: ["acme:read", "acme:write"]
        )
        let params = queryItems(of: ComfyCloudClient.buildAuthorizationRequest(config: custom).authorizationURL)
        #expect(params["client_id"] == "acme-app")
        #expect(params["redirect_uri"] == "com.acme.app://oauth-callback")
        #expect(params["scope"] == "acme:read acme:write")
        // Shared protocol params are unchanged by the client config.
        #expect(params["response_type"] == "code")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["resource"] == "https://cloud.comfy.org/api")
    }

    @Test("default buildAuthorizationRequest() still uses the comfyIOS config")
    func defaultConfigStillComfyIOS() {
        let params = queryItems(of: ComfyCloudClient.buildAuthorizationRequest().authorizationURL)
        #expect(params["client_id"] == "comfy-ios")
        #expect(params["redirect_uri"] == "org.comfy.ios://oauth-callback")
        #expect(params["scope"] == OAuthClientConfig.comfyIOS.scopes.joined(separator: " "))
    }

    // MARK: - extractCode(fromCallback:) matrix

    private func request(state: String) -> OAuthAuthorizationRequest {
        OAuthAuthorizationRequest(
            authorizationURL: URL(string: "https://cloud.comfy.org/oauth/authorize")!,
            state: state,
            codeVerifier: "verifier"
        )
    }

    @Test("extractCode returns the code when state matches")
    func extractCodeValid() throws {
        let req = request(state: "STATE-123")
        let url = URL(string: "org.comfy.ios://oauth-callback?code=auth-code-xyz&state=STATE-123")!
        #expect(try req.extractCode(fromCallback: url) == "auth-code-xyz")
    }

    @Test("extractCode tolerates query-item ordering (state before code)")
    func extractCodeOrderIndependent() throws {
        let req = request(state: "STATE-123")
        let url = URL(string: "org.comfy.ios://oauth-callback?state=STATE-123&code=auth-code-xyz")!
        #expect(try req.extractCode(fromCallback: url) == "auth-code-xyz")
    }

    @Test("extractCode throws .authCancelled on an empty code")
    func extractCodeEmptyCode() {
        let req = request(state: "STATE-123")
        let url = URL(string: "org.comfy.ios://oauth-callback?code=&state=STATE-123")!
        do {
            _ = try req.extractCode(fromCallback: url)
            Issue.record("Expected .authCancelled, got success")
        } catch ComfyError.authCancelled {
        } catch {
            Issue.record("Expected .authCancelled, got \(error)")
        }
    }

    @Test("extractCode throws .authCancelled when code is missing")
    func extractCodeMissingCode() {
        let req = request(state: "STATE-123")
        let url = URL(string: "org.comfy.ios://oauth-callback?state=STATE-123")!
        do {
            _ = try req.extractCode(fromCallback: url)
            Issue.record("Expected .authCancelled, got success")
        } catch ComfyError.authCancelled {
        } catch {
            Issue.record("Expected .authCancelled, got \(error)")
        }
    }

    @Test("extractCode throws .authCancelled when state is missing")
    func extractCodeMissingState() {
        let req = request(state: "STATE-123")
        let url = URL(string: "org.comfy.ios://oauth-callback?code=auth-code-xyz")!
        do {
            _ = try req.extractCode(fromCallback: url)
            Issue.record("Expected .authCancelled, got success")
        } catch ComfyError.authCancelled {
        } catch {
            Issue.record("Expected .authCancelled, got \(error)")
        }
    }

    @Test("extractCode throws .authStateMismatch when state differs")
    func extractCodeStateMismatch() {
        let req = request(state: "STATE-123")
        let url = URL(string: "org.comfy.ios://oauth-callback?code=auth-code-xyz&state=WRONG-STATE")!
        do {
            _ = try req.extractCode(fromCallback: url)
            Issue.record("Expected .authStateMismatch, got success")
        } catch ComfyError.authStateMismatch {
        } catch {
            Issue.record("Expected .authStateMismatch, got \(error)")
        }
    }
}
