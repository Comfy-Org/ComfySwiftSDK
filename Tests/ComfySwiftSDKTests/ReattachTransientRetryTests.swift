import Testing
import Foundation
@testable import ComfySwiftSDK

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
            if statusCalls.next() == 1 {
                throw URLError(.badServerResponse)
            }
            let body = #"""
            {"id":"job-1","status":"completed","create_time":1,"update_time":2,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
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
        } else {
            Issue.record("Expected .complete after transient-retry recovery, got \(String(describing: events.first))")
        }
    }

    @Test("a non-transient catch-up failure terminates with .failed and is not retried")
    func nonTransientCatchUpFailsFast() async throws {
        let statusCalls = CallCounter()
        TestURLProtocol.install { _ in
            _ = statusCalls.next()
            throw NonTransientTestError()
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
        } else {
            Issue.record("Expected .failed for a non-transient catch-up error, got \(String(describing: events.first))")
        }
    }
}
