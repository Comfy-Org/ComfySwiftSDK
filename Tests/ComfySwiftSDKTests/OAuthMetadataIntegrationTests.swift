import Testing
import Foundation
@testable import ComfySwiftSDK

private var runOAuthIntegration: Bool {
    ProcessInfo.processInfo.environment["RUN_OAUTH_INTEGRATION"] == "1"
}

@Suite("OAuthMetadata live integration — AC4")
struct OAuthMetadataIntegrationTests {

    @Test(
        "live AS metadata matches OAuthConfiguration constants",
        .enabled(if: runOAuthIntegration, "Requires seeded comfy-ios OAuth client — set RUN_OAUTH_INTEGRATION=1")
    )
    func liveMetadataMatchesConfiguration() async throws {
        let fetcher = OAuthMetadataFetcher(
            session: URLSession(configuration: .ephemeral)
        )

        let metadata = try await fetcher.fetchAndValidate()

        #expect(metadata.issuer == OAuthConfiguration.issuer.absoluteString)
        #expect(
            metadata.authorizationEndpoint
                == OAuthConfiguration.authorizationEndpoint.absoluteString
        )
        #expect(
            metadata.tokenEndpoint == OAuthConfiguration.tokenEndpoint.absoluteString
        )
        #expect(
            metadata.codeChallengeMethodsSupported?
                .contains(OAuthConfiguration.pkceCodeChallengeMethod) == true
        )
    }

    @Test(
        "seeded comfy-ios client accepts the registered redirect URI",
        .disabled("TODO(8.3): implement after backend seed confirmed — needs the authorize-request plumbing from Story 8.3")
    )
    func seededClientAcceptsRedirectURI() async throws {
    }
}
