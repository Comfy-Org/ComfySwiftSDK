import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("PollingFallback", .serialized)
struct PollingFallbackTests {

    @Test("decodes pending status")
    func decodesPendingStatus() throws {
        let json = #"{"id": "abc-123", "status": "pending", "create_time": 1000, "update_time": 2000}"#
            .data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobDetailResponse.self, from: json)
        #expect(dto.status == "pending")
        #expect(dto.outputs == nil)
    }

    @Test("decodes in_progress status")
    func decodesInProgressStatus() throws {
        let json = #"{"id": "abc-123", "status": "in_progress", "create_time": 1000, "update_time": 2000}"#
            .data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobDetailResponse.self, from: json)
        #expect(dto.status == "in_progress")
        #expect(dto.outputs == nil)
    }

    @Test("decodes completed with outputs")
    func decodesCompletedWithOutputs() throws {
        let json = """
        {
          "id": "abc-123",
          "status": "completed",
          "create_time": 1000,
          "update_time": 3000,
          "outputs": {
            "9": {
              "images": [
                {"filename": "out.png", "subfolder": "", "type": "output"}
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobDetailResponse.self, from: json)
        #expect(dto.status == "completed")
        #expect(dto.outputs?["9"]?.images?.first?.filename == "out.png")
    }

    @Test("decodes failed with execution_error")
    func decodesFailedWithExecutionError() throws {
        let json = """
        {
          "id": "abc-123",
          "status": "failed",
          "create_time": 1000,
          "update_time": 4000,
          "execution_error": {
            "node_id": "3",
            "node_type": "KSampler",
            "exception_message": "out of memory",
            "exception_type": "RuntimeError",
            "traceback": ["line 1", "line 2"]
          }
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobDetailResponse.self, from: json)
        #expect(dto.status == "failed")
        #expect(dto.executionError?.nodeType == "KSampler")
        #expect(dto.executionError?.exceptionMessage == "out of memory")
        #expect(dto.executionError?.exceptionType == "RuntimeError")
    }

    @Test("decodes unknown fields gracefully")
    func decodesUnknownFieldsGracefully() throws {
        let json = #"{"id": "abc", "status": "in_progress", "some_future_field": {"foo": "bar"}, "create_time": 1, "update_time": 2}"#
            .data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobDetailResponse.self, from: json)
        #expect(dto.status == "in_progress")
    }

    @Test("derivePhase returns executing for in_progress status")
    func derivePhaseInProgress() {
        let dto = JobDetailResponse(
            id: "j1",
            status: "in_progress",
            outputs: nil,
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "executing")
    }

    @Test("derivePhase returns queued for pending status")
    func derivePhasePending() {
        let dto = JobDetailResponse(
            id: "j1",
            status: "pending",
            outputs: nil,
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "queued")
    }

    @Test("derivePhase returns saving for completed status")
    func derivePhaseCompleted() {
        let dto = JobDetailResponse(
            id: "j1",
            status: "completed",
            outputs: nil,
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "saving")
    }

    @Test("derivePhase uses node_type from execution_error on failed")
    func derivePhaseFailedWithNodeType() {
        let execErr = JobDetailExecutionError(
            nodeId: "3",
            nodeType: "KSampler",
            exceptionMessage: "oom",
            exceptionType: "RuntimeError",
            traceback: []
        )
        let dto = JobDetailResponse(
            id: "j1",
            status: "failed",
            outputs: nil,
            executionError: execErr,
            createTime: nil,
            updateTime: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "sampling")
    }

    @Test("deriveFraction always returns 0 (HTTP endpoint has no progress bucket)")
    func deriveFractionAlwaysZero() {
        let dto = JobDetailResponse(
            id: "j1",
            status: "in_progress",
            outputs: nil,
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )
        #expect(PollingFallback.deriveFraction(from: dto) == 0.0)
    }

    @Test("backoffDelay ladder: 2s → 4s → 8s cap")
    func backoffLadder() {
        #expect(PollingFallback.backoffDelay(for: 0) == .milliseconds(2000))
        #expect(PollingFallback.backoffDelay(for: 1) == .milliseconds(4000))
        #expect(PollingFallback.backoffDelay(for: 2) == .milliseconds(8000))
        #expect(PollingFallback.backoffDelay(for: 10) == .milliseconds(8000))
    }

    @Test("isTransient identifies retriable errors")
    func isTransient() {
        #expect(PollingFallback.isTransient(.offline))
        #expect(PollingFallback.isTransient(.timeout))
        #expect(PollingFallback.isTransient(.network(underlying: URLError(.timedOut))))
        #expect(PollingFallback.isTransient(.rateLimited(retryAfter: nil)))
        #expect(!PollingFallback.isTransient(.authInvalid))
        #expect(!PollingFallback.isTransient(.contentFiltered))
        #expect(!PollingFallback.isTransient(.jobFailed(phase: "sampling")))
        #expect(!PollingFallback.isTransient(.cancelled))
    }

    @Test("pending → in_progress → completed yields .queued, .progress, .finalizing, .complete")
    func happyPath() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let responses: [String] = [
            #"{"id":"job-1","status":"pending","create_time":1,"update_time":1}"#,
            #"{"id":"job-1","status":"in_progress","create_time":1,"update_time":2}"#,
            #"{"id":"job-1","status":"in_progress","create_time":1,"update_time":3}"#,
            #"""
            {"id":"job-1","status":"completed","create_time":1,"update_time":4,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
            """#,
        ]

        let counter = RequestCounter()

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/view") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
                return (resp, imagePNG)
            }
            if path.contains("/api/prompt/") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (resp, Data())
            }
            let idx = counter.nextAndIncrement()
            let body = responses[min(idx, responses.count - 1)]
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
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
            jobId: "job-1",
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

        #expect(events.contains(where: { if case .queued = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .progress = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .finalizing = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .complete = $0 { return true }; return false }))
        let queuedCount = events.filter { if case .queued = $0 { return true }; return false }.count
        #expect(queuedCount == 1, "Expected exactly one .queued, got \(queuedCount)")
    }

    @Test("failed status yields .failed(.jobFailed)")
    func failedJobPath() async throws {
        TestURLProtocol.install { request in
            let body = #"{"id":"job-1","status":"failed","create_time":1,"update_time":2,"execution_error":{"node_id":"3","node_type":"KSampler","exception_message":"oom","exception_type":"RuntimeError","traceback":[]}}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
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
            jobId: "job-1",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var sawFailed = false
        var failurePhase = ""
        for try await event in polling.eventStream() {
            if case .failed(.jobFailed(let phase)) = event {
                sawFailed = true
                failurePhase = phase
                break
            }
            if case .failed = event { break }
        }

        #expect(sawFailed)
        #expect(failurePhase == "sampling")
    }

    @Test("cancelled status yields .cancelled and closes stream")
    func cancelledStatus() async throws {
        TestURLProtocol.install { request in
            let body = #"{"id":"job-1","status":"cancelled","create_time":1,"update_time":2}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
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
            jobId: "job-1",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var events: [JobEvent] = []
        for try await event in polling.eventStream() {
            events.append(event)
            if case .cancelled = event { break }
            if events.count > 5 { break }
        }
        #expect(events.contains(where: { if case .cancelled = $0 { return true }; return false }))
    }

    @Test("auth invalid surfaces as .failed without backoff loop")
    func authInvalidTerminates() async throws {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (resp, Data())
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("bad-key")
        )
        let polling = PollingFallback(
            transport: transport,
            jobId: "job-1",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var sawAuthInvalid = false
        for try await event in polling.eventStream() {
            if case .failed(.authInvalid) = event {
                sawAuthInvalid = true
                break
            }
        }
        #expect(sawAuthInvalid)
    }

    @Test("de-dup: in_progress with unchanged status does not re-emit .progress")
    func dedupProgress() async throws {
        let counter = RequestCounter()
        let body = #"{"id":"job-1","status":"in_progress","create_time":1,"update_time":2}"#
        let final = #"""
        {"id":"job-1","status":"completed","create_time":1,"update_time":5,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
        """#

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/view") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
                return (resp, Data([0x89, 0x50, 0x4E, 0x47]))
            }
            let idx = counter.nextAndIncrement()
            let payload = idx < 3 ? body : final
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, payload.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let polling = PollingFallback(
            transport: transport,
            jobId: "job-1",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var progressCount = 0
        for try await event in polling.eventStream() {
            if case .progress = event { progressCount += 1 }
            if case .complete = event { break }
            if case .failed = event { break }
        }
        #expect(progressCount == 1, "Expected exactly one .progress (de-dup), got \(progressCount)")
    }

    @Test("fetchJobStatus hits /api/jobs/{id} not /api/prompt/{id}")
    func fetchJobStatusUsesJobsEndpoint() async throws {
        var capturedPath: String?
        TestURLProtocol.install { request in
            capturedPath = request.url?.path
            let body = #"{"id":"job-99","status":"cancelled","create_time":1,"update_time":2}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, body.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        _ = try await transport.fetchJobStatus(id: "job-99")

        #expect(capturedPath == "/api/jobs/job-99",
                "Expected /api/jobs/job-99, got \(capturedPath ?? "nil")")
        #expect(capturedPath?.contains("/api/prompt/") == false,
                "Must NOT hit the tombstoned /api/prompt/ endpoint")
    }
}

final class RequestCounter: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()
    func nextAndIncrement() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value += 1
        return v
    }
}

struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}
