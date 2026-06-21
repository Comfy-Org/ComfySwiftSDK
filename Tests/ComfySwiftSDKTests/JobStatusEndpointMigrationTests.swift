import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Job status endpoint migration", .serialized)
struct JobStatusEndpointMigrationTests {

    @Test("reattach: completed JobDetailResponse resolves to .complete(output)")
    func reattachCompletedResolvesToComplete() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/prompt/") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 404,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            if path.contains("/api/view") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"])!
                return (resp, imagePNG)
            }
            let body = #"""
            {
              "id": "reattach-job-1",
              "status": "completed",
              "create_time": 1000,
              "update_time": 2000,
              "outputs": {
                "9": {
                  "images": [{"filename": "out.png", "subfolder": "", "type": "output"}]
                }
              }
            }
            """#
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "reattach-job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(events.count == 1, "Terminal completed → exactly one event")
        if case .complete(let output) = events.first {
            #expect(!output.files.isEmpty, "Completed job must carry output files")
        } else {
            Issue.record("Expected .complete, got \(String(describing: events.first))")
        }
    }

    @Test("reattach: failed JobDetailResponse with execution_error surfaces .failed(.jobFailed)")
    func reattachFailedSurfacesJobFailed() async throws {
        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/prompt/") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 404,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            let body = #"""
            {
              "id": "reattach-job-2",
              "status": "failed",
              "create_time": 1000,
              "update_time": 3000,
              "execution_error": {
                "node_id": "3",
                "node_type": "KSampler",
                "exception_message": "CUDA out of memory",
                "exception_type": "RuntimeError",
                "traceback": ["Traceback (most recent call last):", "  RuntimeError: CUDA out of memory"]
              }
            }
            """#
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "reattach-job-2")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(events.count == 1, "Terminal failed → exactly one event")
        if case .failed(.jobFailed(let phase)) = events.first {
            #expect(phase == "sampling",
                    "execution_error.node_type must inform the phase label")
        } else {
            Issue.record("Expected .failed(.jobFailed), got \(String(describing: events.first))")
        }
    }

    @Test("polling: completed JobDetailResponse resolves to .complete(output)")
    func pollingCompletedResolvesToComplete() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let counter = RequestCounter()

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/prompt/") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 404,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            if path.contains("/api/view") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"])!
                return (resp, imagePNG)
            }
            let idx = counter.nextAndIncrement()
            let body: String
            if idx == 0 {
                body = #"{"id":"poll-job-1","status":"pending","create_time":1,"update_time":1}"#
            } else {
                body = #"""
                {"id":"poll-job-1","status":"completed","create_time":1,"update_time":2,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
                """#
            }
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let polling = PollingFallback(
            transport: transport,
            jobId: "poll-job-1",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var sawComplete = false
        for try await event in polling.eventStream() {
            if case .complete(let output) = event {
                sawComplete = true
                #expect(!output.files.isEmpty)
                break
            }
            if case .failed = event { break }
            if case .cancelled = event { break }
        }
        #expect(sawComplete)
    }

    @Test("polling: failed JobDetailResponse surfaces .failed(.jobFailed)")
    func pollingFailedSurfacesJobFailed() async throws {
        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/prompt/") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 404,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            let body = #"""
            {
              "id": "poll-job-2",
              "status": "failed",
              "create_time": 1000,
              "update_time": 2000,
              "execution_error": {
                "node_id": "5",
                "node_type": "VAEDecode",
                "exception_message": "tensor shape mismatch",
                "exception_type": "ValueError",
                "traceback": []
              }
            }
            """#
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let polling = PollingFallback(
            transport: transport,
            jobId: "poll-job-2",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var sawFailed = false
        var phase = ""
        for try await event in polling.eventStream() {
            if case .failed(.jobFailed(let p)) = event {
                sawFailed = true
                phase = p
                break
            }
            if case .failed = event { break }
        }
        #expect(sawFailed)
        #expect(phase == "vae_decode")
    }

    @Test("polling: pending then in_progress does not terminate the stream")
    func pollingActiveStatesKeepPolling() async throws {
        let counter = RequestCounter()
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/view") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"])!
                return (resp, imagePNG)
            }
            let idx = counter.nextAndIncrement()
            let body: String
            switch idx {
            case 0:
                body = #"{"id":"poll-job-3","status":"pending","create_time":1,"update_time":1}"#
            case 1, 2:
                body = #"{"id":"poll-job-3","status":"in_progress","create_time":1,"update_time":2}"#
            default:
                body = #"""
                {"id":"poll-job-3","status":"completed","create_time":1,"update_time":3,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
                """#
            }
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let polling = PollingFallback(
            transport: transport,
            jobId: "poll-job-3",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var events: [JobEvent] = []
        for try await event in polling.eventStream() {
            events.append(event)
            if case .complete = event { break }
            if case .failed = event { break }
            if events.count > 20 { break }
        }

        #expect(events.contains(where: { if case .queued = $0 { return true }; return false }),
                "pending must emit .queued")
        #expect(events.contains(where: { if case .complete = $0 { return true }; return false }),
                "stream must eventually reach .complete")
        #expect(!events.contains(where: { if case .failed = $0 { return true }; return false }),
                "pending/in_progress must not yield .failed")
    }

    @Test("fetchJobStatus request URL is /api/jobs/{id}")
    func fetchJobStatusUrlIsJobsEndpoint() async throws {
        var capturedURL: URL?
        TestURLProtocol.install { request in
            capturedURL = request.url
            let body = #"{"id":"url-test-job","status":"cancelled","create_time":1,"update_time":1}"#
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        _ = try await transport.fetchJobStatus(id: "url-test-job")

        let path = capturedURL?.path ?? ""
        #expect(path == "/api/jobs/url-test-job",
                "Expected /api/jobs/url-test-job, got \(path)")
        #expect(!path.contains("/api/prompt/"),
                "Must NOT hit the tombstoned /api/prompt/ endpoint; got \(path)")
    }

    @Test("401 on fetchJobStatus still maps to .authInvalid (not a new error class)")
    func authClassificationUnchanged() async throws {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("bad-key")
        )
        var gotAuthInvalid = false
        do {
            _ = try await transport.fetchJobStatus(id: "auth-test-job")
        } catch ComfyError.authInvalid {
            gotAuthInvalid = true
        } catch {}
        #expect(gotAuthInvalid)
    }

    @Test("429 on fetchJobStatus still maps to .rateLimited")
    func rateLimitClassificationUnchanged() async throws {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "30"])!
            return (resp, Data())
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        var gotRateLimited = false
        do {
            _ = try await transport.fetchJobStatus(id: "rl-test-job")
        } catch ComfyError.rateLimited {
            gotRateLimited = true
        } catch {}
        #expect(gotRateLimited)
    }
}
