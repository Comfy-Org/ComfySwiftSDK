//
//  OAuthMetadataIntegrationTests.swift
//  ComfySwiftSDKTests
//
//  Story 8.1 AC4 — skip-until-seeded live verification of the AS
//  metadata + seeded-client handshake. Gated on the opt-in
//  `RUN_OAUTH_INTEGRATION=1` environment flag (same opt-in pattern as
//  `SmokeIntegrationTests` / the Story 7.6 `RUN_CLOUD_SMOKE` guard)
//  so the default `⌘U` test plan stays green while the cross-team
//  backend gate is open.
//
//  Once the Backend Gate Checklist in the Story 8.1 artifact is green,
//  run with:
//
//    RUN_OAUTH_INTEGRATION=1 xcrun swift test \
//      --package-path Packages/ComfySwiftSDK \
//      --filter OAuthMetadataIntegrationTests
//
//  Story 8.1.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

/// True only when the developer explicitly opted into live OAuth
/// integration runs. Evaluated by the `.enabled(if:)` traits below —
/// the Swift Testing equivalent of the `XCTSkip`-on-missing-env-var
/// guard used by the XCTest-based smoke suite.
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

        // `fetchAndValidate()` already enforces the issuer, endpoint,
        // and S256 byte-matches — reaching the assertions below means
        // the live document passed every gate. The explicit
        // re-assertions pin the exact live byte values in the test
        // output, which is the diagnostic the Backend Gate Checklist
        // needs if the backend ever drifts (e.g. a trailing-slash
        // issuer canonicalization — review M1).
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

    // NOTE: no `.enabled(if: runOAuthIntegration)` trait here — `.disabled`
    // is unconditional and would override it, falsely implying the env
    // flag can run this test (review L4). Story 8.3 removes `.disabled`
    // and adds the `.enabled(if:)` gate back alongside the implementation.
    @Test(
        "seeded comfy-ios client accepts the registered redirect URI",
        .disabled("TODO(8.3): implement after backend seed confirmed — needs the authorize-request plumbing from Story 8.3")
    )
    func seededClientAcceptsRedirectURI() async throws {
        // TODO(8.3): implement after backend seed confirmed.
        //
        // Once Story 8.3 lands the authorize-request construction, this
        // test will issue a GET to `OAuthConfiguration.authorizationEndpoint`
        // with `client_id=comfy-ios`, `redirect_uri=OAuthConfiguration.redirectURI`,
        // a throwaway PKCE challenge, and `resource=OAuthConfiguration.resourceParameter`,
        // then assert the server does NOT reject the redirect URI
        // (i.e. no `invalid_redirect_uri` error response) — confirming
        // Backend Gate Checklist item 2 (byte-identical seed) end-to-end.
    }
}
