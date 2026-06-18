//
//  PollingFallbackTests.swift
//  ComfySwiftSDKTests
//
//  Story 4.4 AC8 — unit tests for `PollingFallback`.
//
//  Covers:
//    - Wire-format decoding (`JobStatusDTO` shapes for queued / running / success / error / cancelled)
//    - `JobEvent` mapping parity with `WebSocketSession`
//    - De-duplication (no duplicate `.queued`, no repeat `.progress`)
//    - Exponential backoff on transport errors (ladder: 2s → 4s → 8s cap)
//    - Terminal-state output download via `Transport`
//
//  Uses `TestURLProtocol` to stub HTTP responses — no real network.
//
//  Story 4.4.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("PollingFallback", .serialized)
struct PollingFallbackTests {

    // MARK: - JobStatusDTO decoding

    @Test("decodes queued status")
    func decodesQueuedStatus() throws {
        let json = #"{"status": "queued"}"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobStatusDTO.self, from: json)
        #expect(dto.status == "queued")
        #expect(dto.progress == nil)
        #expect(dto.outputs == nil)
    }

    @Test("decodes running with progress")
    func decodesRunningWithProgress() throws {
        let json = #"{"status": "running", "progress": {"value": 5, "max": 20}, "node": "KSampler"}"#
            .data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobStatusDTO.self, from: json)
        #expect(dto.status == "running")
        #expect(dto.progress?.value == 5)
        #expect(dto.progress?.max == 20)
        #expect(dto.node == "KSampler")
    }

    @Test("decodes success with outputs")
    func decodesSuccessWithOutputs() throws {
        let json = """
        {
          "status": "success",
          "outputs": {
            "9": {
              "images": [
                {"filename": "out.png", "subfolder": "", "type": "output"}
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobStatusDTO.self, from: json)
        #expect(dto.status == "success")
        #expect(dto.outputs?["9"]?.images?.first?.filename == "out.png")
    }

    @Test("decodes unknown fields gracefully")
    func decodesUnknownFieldsGracefully() throws {
        let json = #"{"status": "running", "some_future_field": {"foo": "bar"}}"#
            .data(using: .utf8)!
        let dto = try JSONDecoder().decode(JobStatusDTO.self, from: json)
        #expect(dto.status == "running")
    }

    // MARK: - Phase derivation (parity with WebSocketSession)

    @Test("derivePhase returns sampling for KSampler node")
    func derivePhaseSampling() {
        let dto = JobStatusDTO(
            status: "running",
            progress: nil,
            node: "KSampler",
            outputs: nil,
            error: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "sampling")
    }

    @Test("derivePhase returns vae_decode for VAEDecode")
    func derivePhaseVAE() {
        let dto = JobStatusDTO(
            status: "running",
            progress: nil,
            node: "VAEDecode",
            outputs: nil,
            error: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "vae_decode")
    }

    @Test("derivePhase returns queued for queued status without node")
    func derivePhaseQueued() {
        let dto = JobStatusDTO(
            status: "queued",
            progress: nil,
            node: nil,
            outputs: nil,
            error: nil
        )
        #expect(PollingFallback.derivePhase(from: dto) == "queued")
    }

    // MARK: - Fraction clamping

    @Test("deriveFraction clamps to [0, 1]")
    func deriveFractionClamps() {
        let over = JobStatusDTO(
            status: "running",
            progress: .init(value: 30, max: 20),
            node: nil,
            outputs: nil,
            error: nil
        )
        #expect(PollingFallback.deriveFraction(from: over) == 1.0)
    }

    @Test("deriveFraction returns 0 for nil progress")
    func deriveFractionNil() {
        let none = JobStatusDTO(
            status: "running",
            progress: nil,
            node: nil,
            outputs: nil,
            error: nil
        )
        #expect(PollingFallback.deriveFraction(from: none) == 0.0)
    }

    @Test("deriveFraction collapses NaN / divide-by-zero to 0")
    func deriveFractionNaN() {
        let zero = JobStatusDTO(
            status: "running",
            progress: .init(value: 0, max: 0),
            node: nil,
            outputs: nil,
            error: nil
        )
        #expect(PollingFallback.deriveFraction(from: zero) == 0.0)
    }

    // MARK: - Backoff ladder

    @Test("backoffDelay ladder: 2s → 4s → 8s cap")
    func backoffLadder() {
        #expect(PollingFallback.backoffDelay(for: 0) == .milliseconds(2000))
        #expect(PollingFallback.backoffDelay(for: 1) == .milliseconds(4000))
        #expect(PollingFallback.backoffDelay(for: 2) == .milliseconds(8000))
        // Beyond the ladder: clamped to the last rung.
        #expect(PollingFallback.backoffDelay(for: 10) == .milliseconds(8000))
    }

    @Test("isTransient identifies retriable errors")
    func isTransient() {
        #expect(PollingFallback.isTransient(.offline))
        #expect(PollingFallback.isTransient(.timeout))
        #expect(PollingFallback.isTransient(.network(underlying: URLError(.timedOut))))
        #expect(PollingFallback.isTransient(.rateLimited(retryAfter: nil)))
        // Non-transient:
        #expect(!PollingFallback.isTransient(.authInvalid))
        #expect(!PollingFallback.isTransient(.contentFiltered))
        #expect(!PollingFallback.isTransient(.jobFailed(phase: "sampling")))
        #expect(!PollingFallback.isTransient(.cancelled))
    }

    // MARK: - End-to-end via TestURLProtocol

    @Test("queued → running → success yields .queued, .progress, .finalizing, .complete")
    func happyPath() async throws {
        // Drive the sequence of responses the stub returns. Each
        // request pops the next scripted reply; we return the image
        // bytes on the /api/view call.
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let responses: [(String, String)] = [
            ("/api/prompt/job-1", #"{"status": "queued"}"#),
            ("/api/prompt/job-1", #"{"status": "running", "progress": {"value": 2, "max": 10}, "node": "KSampler"}"#),
            ("/api/prompt/job-1", #"{"status": "running", "progress": {"value": 10, "max": 10}, "node": "KSampler"}"#),
            ("/api/prompt/job-1", #"""
            {"status": "success", "outputs": {"9": {"images": [{"filename": "out.png", "subfolder": "", "type": "output"}]}}}
            """#),
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
            let idx = counter.nextAndIncrement()
            let (_, body) = responses[min(idx, responses.count - 1)]
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

        // Must contain .queued, at least one .progress, .finalizing, .complete
        #expect(events.contains(where: { if case .queued = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .progress = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .finalizing = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .complete = $0 { return true }; return false }))
        // De-dup: exactly one .queued.
        let queuedCount = events.filter { if case .queued = $0 { return true }; return false }.count
        #expect(queuedCount == 1, "Expected exactly one .queued, got \(queuedCount)")
    }

    @Test("server error status yields .failed(.jobFailed)")
    func failedJobPath() async throws {
        TestURLProtocol.install { request in
            let body = #"{"status": "error", "node": "KSampler"}"#
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
            let body = #"{"status": "cancelled"}"#
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

    @Test("de-dup: running with unchanged phase + fraction does not re-emit")
    func dedupProgress() async throws {
        let counter = RequestCounter()
        let body = #"{"status": "running", "progress": {"value": 2, "max": 10}, "node": "KSampler"}"#
        let final = #"""
        {"status": "success", "outputs": {"9": {"images": [{"filename": "out.png", "subfolder": "", "type": "output"}]}}}
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
        // Three identical running payloads should only produce ONE .progress
        #expect(progressCount == 1, "Expected exactly one .progress (de-dup), got \(progressCount)")
    }
}

// MARK: - Test helpers

/// Thread-safe counter for scripted response sequences.
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

/// A `Clock` that returns immediately from every `sleep(for:)` call so
/// tests don't actually wait for polling / backoff intervals.
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
