//
//  OAuthExchangeTests.swift
//  ComfySwiftSDKTests
//
//  Story 8.3 AC5 — unit coverage for the client side of the PKCE
//  authorization-code flow: `ComfyCloudClient.buildAuthorizationRequest()`
//  (authorize-URL construction, verifier/challenge/state generation)
//  and `OAuthExchanger.exchange(code:codeVerifier:)` against a mocked
//  token endpoint via `TestURLProtocol`. No live network — the live
//  end-to-end check is gated on `RUN_OAUTH_INTEGRATION=1` below until
//  the `comfy-ios` backend client is seeded (Story 8.1 gate).
//
//  Covers:
//    - Authorize URL carries every required parameter (AC1)
//    - code_verifier is 43 base64url chars and fresh per attempt
//    - code_challenge == BASE64URL(SHA256(code_verifier)) (RFC 7636)
//    - state is fresh per attempt
//    - Exchange request: POST, form-encoded, all params, no client_secret (AC2)
//    - Exchange success → decoded OAuthTokenResponse
//    - HTTP 401 → .authInvalid, HTTP 400 → ComfyError (Transport.checkStatus)
//    - Malformed token JSON → .unknown(underlying:)
//
//  Story 8.3.
//

import Testing
import Foundation
import CryptoKit
@testable import ComfySwiftSDK

@Suite("OAuthExchange — AC1/AC2/AC5", .serialized)
struct OAuthExchangeTests {

    // MARK: - Helpers

    /// The base64url alphabet RFC 7636 §4.1 permits for a verifier.
    private static let base64URLAlphabet = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    /// Parse the query items of a URL into a dictionary (last write
    /// wins — the authorize URL never repeats a name).
    private func queryItems(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    /// Drain a captured `URLRequest`'s body. `URLProtocol` surfaces
    /// POST bodies as `httpBodyStream`, not `httpBody`, so read the
    /// stream when the plain property is nil.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// Decode an `application/x-www-form-urlencoded` body into a
    /// dictionary of percent-DECODED key/value pairs.
    private func formFields(_ body: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        let items = components.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    private func makeExchanger() -> OAuthExchanger {
        OAuthExchanger(session: TestURLProtocol.makeStubSession())
    }

    /// Install a `TestURLProtocol` handler answering with the given
    /// status + JSON body, capturing each request into `box`.
    private func installTokenEndpoint(
        status: Int,
        body: String,
        capture box: CapturedRequestBox? = nil
    ) {
        TestURLProtocol.install { request in
            box?.store(request, body: Self.bodyData(of: request))
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, body.data(using: .utf8)!)
        }
    }

    /// Thread-safe box for the request the stub handler captured.
    final class CapturedRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: URLRequest?
        private var _body = Data()
        func store(_ request: URLRequest, body: Data) {
            lock.lock(); defer { lock.unlock() }
            _request = request
            _body = body
        }
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return _request }
        var body: Data { lock.lock(); defer { lock.unlock() }; return _body }
    }

    // MARK: - buildAuthorizationRequest (AC1, Tasks 7.3–7.6)

    @Test("buildAuthorizationRequest — all required params present and correct")
    func authorizeURLCarriesAllRequiredParams() throws {
        let request = ComfyCloudClient.buildAuthorizationRequest()
        let url = request.authorizationURL

        #expect(url.absoluteString.hasPrefix(
            OAuthConfiguration.authorizationEndpoint.absoluteString + "?"
        ))

        let params = queryItems(of: url)
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "comfy-ios")
        #expect(params["state"]?.isEmpty == false)
        #expect(params["code_challenge"]?.isEmpty == false)
        #expect(params["code_challenge_method"] == "S256")
        // Server requires non-empty scope at parse time (request.go:63,
        // ErrEmptyScope) — omitting it is the "invalid authorization
        // request parameters" failure found in live testing 2026-06-11.
        #expect(params["scope"] == OAuthConfiguration.scope)
        #expect(params["scope"]?.isEmpty == false)
        #expect(params["resource"] == "https://cloud.comfy.org/api")
        #expect(params["redirect_uri"] == "org.comfy.ios://oauth-callback")

        // The URL's state must be the same value the app is told to
        // verify against the callback.
        #expect(params["state"] == request.state)
    }

    @Test("code_verifier is 43 base64url chars and fresh per attempt")
    func codeVerifierLengthAndFreshness() {
        let first = ComfyCloudClient.buildAuthorizationRequest()
        let second = ComfyCloudClient.buildAuthorizationRequest()

        // base64url of 32 bytes without padding = exactly 43 chars
        // (RFC 7636 requires 43–128).
        #expect(first.codeVerifier.count == 43)
        #expect(second.codeVerifier.count == 43)
        #expect(first.codeVerifier.allSatisfy { Self.base64URLAlphabet.contains($0) })
        #expect(second.codeVerifier.allSatisfy { Self.base64URLAlphabet.contains($0) })

        // Fresh per attempt — verifier reuse breaks the PKCE guarantee.
        #expect(first.codeVerifier != second.codeVerifier)
    }

    @Test("code_challenge is BASE64URL(SHA256(code_verifier))")
    func codeChallengeIsS256OfVerifier() throws {
        let request = ComfyCloudClient.buildAuthorizationRequest()

        let digest = SHA256.hash(data: Data(request.codeVerifier.utf8))
        let expected = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(queryItems(of: request.authorizationURL)["code_challenge"] == expected)
    }

    @Test("state is fresh per attempt")
    func stateFreshness() {
        let states = (0..<3).map { _ in ComfyCloudClient.buildAuthorizationRequest().state }
        #expect(Set(states).count == 3)
    }

    // MARK: - Exchange request encoding (AC2, Task 7.7)

    @Test("exchange request is a form-encoded POST with all params and no client_secret")
    func exchangeRequestBodyEncoding() async throws {
        let verifier = "test-verifier-43chars-aaaaaaaaaaaaaaaaaaaaa"
        let box = CapturedRequestBox()
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at","refresh_token":"rt","expires_in":900,"token_type":"Bearer"}"#,
            capture: box
        )
        defer { TestURLProtocol.uninstall() }

        _ = try await makeExchanger().exchange(code: "test-code", codeVerifier: verifier)

        let request = try #require(box.request)
        #expect(request.url == OAuthConfiguration.tokenEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")?
                .contains("application/x-www-form-urlencoded") == true
        )

        let fields = formFields(box.body)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "test-code")
        #expect(fields["code_verifier"] == verifier)
        #expect(fields["client_id"] == "comfy-ios")
        #expect(fields["resource"] == "https://cloud.comfy.org/api")
        #expect(fields["redirect_uri"] == "org.comfy.ios://oauth-callback")

        // Public client — a client_secret in the body would mean a
        // secret shipped on-device (token_endpoint_auth_method=none).
        #expect(fields["client_secret"] == nil)
    }

    // MARK: - Exchange responses (AC2/AC4, Tasks 7.8–7.11)

    @Test("exchange success decodes to OAuthTokenResponse")
    func exchangeSuccessDecodesTokenResponse() async throws {
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at-abc","refresh_token":"rt-xyz","expires_in":900,"token_type":"Bearer"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let response = try await makeExchanger().exchange(
            code: "good-code",
            codeVerifier: "verifier"
        )

        #expect(response.accessToken == "at-abc")
        #expect(response.refreshToken == "rt-xyz")
        #expect(response.expiresIn == 900)
    }

    @Test("exchange HTTP 401 throws .authInvalid")
    func exchange401ThrowsAuthInvalid() async throws {
        installTokenEndpoint(status: 401, body: #"{"error":"invalid_client"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "c", codeVerifier: "v")
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
            // expected
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("exchange HTTP 400 (bad code) throws a ComfyError, never a raw error")
    func exchange400ThrowsComfyError() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_grant"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "expired", codeVerifier: "v")
            Issue.record("Expected a ComfyError, got success")
        } catch is ComfyError {
            // expected — taxonomy boundary holds (no raw URLError /
            // DecodingError escapes the SDK)
        } catch {
            Issue.record("Expected a ComfyError, got \(error)")
        }
    }

    @Test("exchange malformed JSON throws .unknown(underlying:)")
    func exchangeMalformedJSONThrowsUnknown() async throws {
        installTokenEndpoint(status: 200, body: "not-json")
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "c", codeVerifier: "v")
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown {
            // expected
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }
}

// MARK: - Live integration (gated, Task 7.12)

/// True only when the developer explicitly opted into live OAuth
/// integration runs — same opt-in pattern as
/// `OAuthMetadataIntegrationTests` (Story 8.1 AC4).
private var runOAuthIntegration: Bool {
    ProcessInfo.processInfo.environment["RUN_OAUTH_INTEGRATION"] == "1"
}

@Suite("OAuthExchange — live integration (gated)")
struct OAuthExchangeIntegrationTests {

    // TODO(backend-gate): remove skip once comfy-ios client is seeded
    // (Story 8.1 Backend Gate Checklist).
    @Test(
        "live authorize endpoint accepts the seeded comfy-ios client and redirect URI",
        .enabled(if: runOAuthIntegration, "Requires seeded comfy-ios OAuth client — set RUN_OAUTH_INTEGRATION=1")
    )
    func liveAuthorizeEndpointAcceptsSeededClient() async throws {
        // A GET to the fully-formed authorize URL must not be rejected
        // for the client or redirect URI — the server should answer
        // with the login flow (2xx or a redirect), not an OAuth error.
        let request = ComfyCloudClient.buildAuthorizationRequest()
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(
            for: URLRequest(url: request.authorizationURL)
        )

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode < 400, "authorize endpoint rejected the request with \(http.statusCode)")

        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(!body.contains("invalid_client"))
        #expect(!body.contains("invalid_redirect_uri"))
    }
}
