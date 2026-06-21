import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("CredentialMode — Story 8.2 AC2/AC3", .serialized)
struct CredentialModeTests {

    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var _bodies: [Data?] = []

        func record(_ request: URLRequest, body: Data?) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
            _bodies.append(body)
        }

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        var bodies: [Data?] {
            lock.lock(); defer { lock.unlock() }
            return _bodies
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _requests.count
        }
    }

    private static func drainBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

    private static let baseURL = URL(string: "https://cloud.comfy.org")!

    private func makeTransport(credential: ComfyCredential) -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: Self.baseURL,
            credential: credential
        )
    }

    private func installCapture(
        status: Int = 200,
        body: String = "{}"
    ) -> RequestCapture {
        let capture = RequestCapture()
        TestURLProtocol.install { request in
            capture.record(request, body: Self.drainBody(request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }
        return capture
    }

    private func extractTransportCredential(from client: ComfyCloudClient) -> ComfyCredential? {
        let clientMirror = Mirror(reflecting: client)
        guard let transport = clientMirror.children
            .first(where: { $0.label == "transport" })?.value else {
            return nil
        }
        let transportMirror = Mirror(reflecting: transport)
        return transportMirror.children
            .first(where: { $0.label == "credential" })?.value as? ComfyCredential
    }

    private struct ProviderFailure: Error {}

    @Test(".apiKey mode injects X-API-Key and no Authorization header")
    func apiKeyModeInjectsAPIKeyHeader() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key-123"))
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-key-123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(".oauth mode injects Authorization: Bearer and no X-API-Key header")
    func oauthModeInjectsBearerHeader() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "test-access-token-abc123" })
        )
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token-abc123")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test("validate() in API-key mode succeeds on 200")
    func validateAPIKeySuccess() async throws {
        _ = installCapture(status: 200)
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key"))
        try await transport.validateAuth()
    }

    @Test("validate() in API-key mode throws .authInvalid on 401")
    func validateAPIKey401ThrowsAuthInvalid() async throws {
        _ = installCapture(status: 401, body: #"{"error":"unauthorized"}"#)
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key"))
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("validate() in OAuth mode succeeds on 200 with Bearer header")
    func validateOAuthSuccess() async throws {
        let capture = installCapture(status: 200)
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "test-access-token-abc123" })
        )
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token-abc123")
    }

    @Test("validate() in OAuth mode throws .authInvalid on 401")
    func validateOAuth401ThrowsAuthInvalid() async throws {
        _ = installCapture(status: 401, body: #"{"error":"unauthorized"}"#)
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "stale-token" })
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("validate() in OAuth mode maps a failing token provider to .authInvalid before any network call")
    func validateOAuthProviderFailureThrowsAuthInvalid() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { throw ProviderFailure() })
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }

        #expect(capture.count == 0)
    }

    @Test("validate() in OAuth mode maps an empty token to .authInvalid before any network call")
    func validateOAuthEmptyTokenThrowsAuthInvalid() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "" })
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }

        #expect(capture.count == 0)
    }

    @Test("submit in .apiKey mode sends the Story 1.5 request contract: X-API-Key header, {\"prompt\": ...} body, no Authorization")
    func apiKeySubmitRegression() async throws {
        let capture = installCapture(
            status: 200,
            body: #"{"prompt_id":"prompt-42"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let workflow: [String: Any] = [
            "3": [
                "class_type": "KSampler",
                "inputs": ["seed": 42, "steps": 20]
            ]
        ]
        let transport = makeTransport(credential: .apiKey("test-key-123"))
        let handle = try await transport.submitJob(
            WorkflowRequest(workflowJSON: workflow)
        )

        #expect(handle.id == "prompt-42")

        let request = try #require(capture.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/prompt")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-key-123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(capture.bodies.first.flatMap { $0 })
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(Set(parsed.keys) == ["prompt"])
        let sentPrompt = try #require(parsed["prompt"] as? [String: Any])
        #expect(NSDictionary(dictionary: sentPrompt) == NSDictionary(dictionary: workflow))
    }

    @Test("submit in .oauth mode injects extra_data.auth_token_comfy_org matching the Authorization header token")
    func oauthSubmitInjectsAuthTokenExtraData() async throws {
        let capture = installCapture(
            status: 200,
            body: #"{"prompt_id":"prompt-77"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let workflow: [String: Any] = [
            "3": [
                "class_type": "KSampler",
                "inputs": ["seed": 7, "steps": 20]
            ]
        ]
        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "oauth-token-abc" })
        )
        let handle = try await transport.submitJob(
            WorkflowRequest(workflowJSON: workflow)
        )

        #expect(handle.id == "prompt-77")

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token-abc")

        let bodyData = try #require(capture.bodies.first.flatMap { $0 })
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(Set(parsed.keys) == ["prompt", "extra_data"])
        let extra = try #require(parsed["extra_data"] as? [String: Any])
        #expect(extra["auth_token_comfy_org"] as? String == "oauth-token-abc")
        #expect(Set(extra.keys) == ["auth_token_comfy_org"])
    }

    @Test("submit in .oauth mode merges caller extraData and overwrites a stale auth_token_comfy_org")
    func oauthSubmitMergesCallerExtraData() async throws {
        let capture = installCapture(
            status: 200,
            body: #"{"prompt_id":"prompt-78"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "fresh-token" })
        )
        _ = try await transport.submitJob(
            WorkflowRequest(
                workflowJSON: ["3": ["class_type": "KSampler"]],
                extraData: [
                    "client_info": "test-rider",
                    "auth_token_comfy_org": "stale-token"
                ]
            )
        )

        let bodyData = try #require(capture.bodies.first.flatMap { $0 })
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let extra = try #require(parsed["extra_data"] as? [String: Any])
        #expect(extra["client_info"] as? String == "test-rider")
        #expect(extra["auth_token_comfy_org"] as? String == "fresh-token")
    }

    @Test("submit in .apiKey mode never injects auth_token_comfy_org")
    func apiKeySubmitNeverInjectsAuthToken() async throws {
        let capture = installCapture(
            status: 200,
            body: #"{"prompt_id":"prompt-79"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key-123"))
        _ = try await transport.submitJob(
            WorkflowRequest(
                workflowJSON: ["3": ["class_type": "KSampler"]],
                extraData: ["api_key_comfy_org": "test-key-123"]
            )
        )

        let bodyData = try #require(capture.bodies.first.flatMap { $0 })
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let extra = try #require(parsed["extra_data"] as? [String: Any])
        #expect(extra["api_key_comfy_org"] as? String == "test-key-123")
        #expect(extra["auth_token_comfy_org"] == nil)
    }

    @Test("init(apiKey:) delegates to init(credential:) with an identical stored credential")
    func initAPIKeyDelegationIsTransparent() async throws {
        let viaLegacy = ComfyCloudClient(apiKey: "test-key")
        let viaCredential = ComfyCloudClient(credential: .apiKey("test-key"))

        let legacyCredential = try #require(extractTransportCredential(from: viaLegacy))
        let newCredential = try #require(extractTransportCredential(from: viaCredential))

        guard case .apiKey(let legacyKey) = legacyCredential else {
            Issue.record("init(apiKey:) did not store an .apiKey credential: \(legacyCredential)")
            return
        }
        guard case .apiKey(let newKey) = newCredential else {
            Issue.record("init(credential:) did not store an .apiKey credential: \(newCredential)")
            return
        }
        #expect(legacyKey == "test-key")
        #expect(newKey == "test-key")
        #expect(legacyKey == newKey)
    }
}
