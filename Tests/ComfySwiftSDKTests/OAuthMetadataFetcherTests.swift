import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("OAuthMetadataFetcher — AC2", .serialized)
struct OAuthMetadataFetcherTests {

    private func installJSON(_ body: String) {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, body.data(using: .utf8)!)
        }
    }

    private func installStatus(_ statusCode: Int, body: String = #"{"error":"server_error"}"#) {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, body.data(using: .utf8)!)
        }
    }

    private func makeFetcher() -> OAuthMetadataFetcher {
        OAuthMetadataFetcher(session: TestURLProtocol.makeStubSession())
    }

    @Test("valid metadata with matching issuer and S256 succeeds with parsed values")
    func validMetadataSucceeds() async throws {
        installJSON(#"""
        {
          "issuer": "https://cloud.comfy.org",
          "authorization_endpoint": "https://cloud.comfy.org/oauth/authorize",
          "token_endpoint": "https://cloud.comfy.org/oauth/token",
          "code_challenge_methods_supported": ["S256"]
        }
        """#)
        defer { TestURLProtocol.uninstall() }

        let metadata = try await makeFetcher().fetchAndValidate()

        #expect(metadata.issuer == "https://cloud.comfy.org")
        #expect(metadata.authorizationEndpoint == "https://cloud.comfy.org/oauth/authorize")
        #expect(metadata.tokenEndpoint == "https://cloud.comfy.org/oauth/token")
        #expect(metadata.codeChallengeMethodsSupported == ["S256"])
    }

    @Test("mismatched issuer throws .authInvalid")
    func mismatchedIssuerThrowsAuthInvalid() async throws {
        installJSON(#"""
        {
          "issuer": "https://evil.example.com",
          "authorization_endpoint": "https://evil.example.com/oauth/authorize",
          "token_endpoint": "https://evil.example.com/oauth/token",
          "code_challenge_methods_supported": ["S256"]
        }
        """#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("mismatched authorization_endpoint throws .authInvalid")
    func mismatchedAuthorizationEndpointThrowsAuthInvalid() async throws {
        installJSON(#"""
        {
          "issuer": "https://cloud.comfy.org",
          "authorization_endpoint": "https://evil.example.com/oauth/authorize",
          "token_endpoint": "https://cloud.comfy.org/oauth/token",
          "code_challenge_methods_supported": ["S256"]
        }
        """#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("mismatched token_endpoint throws .authInvalid")
    func mismatchedTokenEndpointThrowsAuthInvalid() async throws {
        installJSON(#"""
        {
          "issuer": "https://cloud.comfy.org",
          "authorization_endpoint": "https://cloud.comfy.org/oauth/authorize",
          "token_endpoint": "https://evil.example.com/oauth/token",
          "code_challenge_methods_supported": ["S256"]
        }
        """#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("code_challenge_methods_supported without S256 throws .authInvalid")
    func missingS256ThrowsAuthInvalid() async throws {
        installJSON(#"""
        {
          "issuer": "https://cloud.comfy.org",
          "authorization_endpoint": "https://cloud.comfy.org/oauth/authorize",
          "token_endpoint": "https://cloud.comfy.org/oauth/token",
          "code_challenge_methods_supported": ["RS256", "plain"]
        }
        """#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("absent code_challenge_methods_supported throws .authInvalid")
    func absentMethodsThrowsAuthInvalid() async throws {
        installJSON(#"""
        {
          "issuer": "https://cloud.comfy.org",
          "authorization_endpoint": "https://cloud.comfy.org/oauth/authorize",
          "token_endpoint": "https://cloud.comfy.org/oauth/token"
        }
        """#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("malformed JSON throws .unknown(underlying:)")
    func malformedJSONThrowsUnknown() async throws {
        installJSON(#"{"issuer": 42, "authorization_endpoint"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown {
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }

    @Test("URLError.notConnectedToInternet throws .offline")
    func notConnectedThrowsOffline() async throws {
        TestURLProtocol.install { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .offline, got success")
        } catch ComfyError.offline {
        } catch {
            Issue.record("Expected .offline, got \(error)")
        }
    }

    @Test("generic URLError throws .network(underlying:)")
    func genericURLErrorThrowsNetwork() async throws {
        TestURLProtocol.install { _ in
            throw URLError(.badServerResponse)
        }
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .network, got success")
        } catch ComfyError.network {
        } catch {
            Issue.record("Expected .network, got \(error)")
        }
    }

    @Test("HTTP 401 throws .authInvalid, not .unknown")
    func http401ThrowsAuthInvalid() async throws {
        installStatus(401, body: #"{"error":"unauthorized"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("HTTP 503 throws .network(underlying:), not .unknown")
    func http503ThrowsNetwork() async throws {
        installStatus(503, body: "Service Unavailable")
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .network, got success")
        } catch ComfyError.network {
        } catch {
            Issue.record("Expected .network, got \(error)")
        }
    }

    @Test("URLError.networkConnectionLost throws .offline")
    func connectionLostThrowsOffline() async throws {
        TestURLProtocol.install { _ in
            throw URLError(.networkConnectionLost)
        }
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .offline, got success")
        } catch ComfyError.offline {
        } catch {
            Issue.record("Expected .offline, got \(error)")
        }
    }

    @Test("URLError.timedOut throws .timeout")
    func timedOutThrowsTimeout() async throws {
        TestURLProtocol.install { _ in
            throw URLError(.timedOut)
        }
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .timeout, got success")
        } catch ComfyError.timeout {
        } catch {
            Issue.record("Expected .timeout, got \(error)")
        }
    }

    @Test("URLError.cancelled throws .cancelled")
    func cancelledThrowsCancelled() async throws {
        TestURLProtocol.install { _ in
            throw URLError(.cancelled)
        }
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeFetcher().fetchAndValidate()
            Issue.record("Expected .cancelled, got success")
        } catch ComfyError.cancelled {
        } catch {
            Issue.record("Expected .cancelled, got \(error)")
        }
    }
}
