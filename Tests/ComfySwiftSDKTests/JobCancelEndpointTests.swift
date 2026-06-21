import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Job cancel endpoint migration", .serialized)
struct JobCancelEndpointTests {

    final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func record(_ request: URLRequest) {
            lock.lock(); requests.append(request); lock.unlock()
        }
        var all: [URLRequest] {
            lock.lock(); defer { lock.unlock() }; return requests
        }
    }

    @Test("cancelJob posts to POST /api/jobs/{job_id}/cancel (not the deprecated /api/queue delete)")
    func cancelHitsJobsCancelEndpoint() async {
        let box = RequestBox()
        TestURLProtocol.install { request in
            box.record(request)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, #"{"cancelled": true}"#.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        await transport.cancelJob(id: "abc-123")

        let captured = box.all
        #expect(captured.count == 1)
        #expect(captured.first?.url?.path == "/api/jobs/abc-123/cancel")
        #expect(captured.first?.httpMethod == "POST")
    }
}
