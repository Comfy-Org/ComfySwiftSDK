//
//  ReattachTransientRetryTests.swift
//  ComfySwiftSDKTests
//
//  The reattach catch-up GET must retry a *transient* failure
//  (e.g. NSURLErrorBadServerResponse / -1011 thrown by a socket the OS
//  just resumed from suspension) instead of surfacing it as a terminal
//  `.failed`. A non-transient failure must still terminate immediately,
//  with no infinite retry.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

/// Thread-safe call counter for the stub handler (called off the
/// URL-loading queue, so it must be safe to mutate concurrently).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func peek() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct NonTransientTestError: Error {}

@Suite("Reattach transient-retry", .serialized)
struct ReattachTransientRetryTests {

    @Test("catch-up GET retries a transient failure and recovers to .complete")
    func transientCatchUpRetryRecovers() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let statusCalls = CallCounter()
        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/view") {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
                return (resp, imagePNG)
            }
            // Catch-up status fetch: fail transiently on the FIRST attempt
            // (mirrors the -1011 a just-resumed socket throws), succeed after.
            if statusCalls.next() == 1 {
                throw URLError(.badServerResponse)
            }
            let body = #"""
            {"status": "success", "outputs": {"9": {"images": [{"filename": "out.png", "subfolder": "", "type": "output"}]}}}
            """#
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
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
        let coordinator = ReattachCoordinator(transport: transport, clock: ImmediateClock())
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(statusCalls.peek() >= 2, "Catch-up GET should have been retried after the transient failure")
        #expect(events.count == 1, "Expected exactly one event, got \(events.count): \(events)")
        if case .complete = events.first {
            // recovered — the transient blip was retried, terminal job resolved
        } else {
            Issue.record("Expected .complete after transient-retry recovery, got \(String(describing: events.first))")
        }
    }

    @Test("a non-transient catch-up failure terminates with .failed and is not retried")
    func nonTransientCatchUpFailsFast() async throws {
        let statusCalls = CallCounter()
        TestURLProtocol.install { _ in
            _ = statusCalls.next()
            throw NonTransientTestError()   // → ComfyError.unknown → not transient
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let coordinator = ReattachCoordinator(transport: transport, clock: ImmediateClock())
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(statusCalls.peek() == 1, "Non-transient failure must not be retried, got \(statusCalls.peek()) call(s)")
        if case .failed = events.first {
            // ok — surfaced as a terminal failure, exactly once
        } else {
            Issue.record("Expected .failed for a non-transient catch-up error, got \(String(describing: events.first))")
        }
    }
}
