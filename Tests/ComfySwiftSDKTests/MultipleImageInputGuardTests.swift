import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Multiple image input guard", .serialized)
struct MultipleImageInputGuardTests {

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

    private func makeTransport() -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
    }

    private func twoImageRequest() -> WorkflowRequest {
        WorkflowRequest(
            workflowJSON: ["1": ["class_type": "LoadImage", "inputs": ["image": ""]]],
            inputs: [
                .image(Data([0x01]), mimeType: "image/png"),
                .image(Data([0x02]), mimeType: "image/png")
            ]
        )
    }

    @Test("submitJob rejects >1 image input with a descriptive serverRejected error")
    func rejectsMultipleImagesWithDescriptiveError() async {
        let transport = makeTransport()
        do {
            _ = try await transport.submitJob(twoImageRequest())
            Issue.record("expected submitJob to throw on multiple image inputs")
        } catch let ComfyError.serverRejected(reason: .other(identifier)) {
            #expect(identifier == "multiple_image_inputs_unsupported")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("submitJob fails fast on >1 image input before any network call")
    func failsFastBeforeAnyNetworkCall() async {
        let box = RequestBox()
        TestURLProtocol.install { request in
            box.record(request)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (resp, #"{"name": "uploaded.png"}"#.data(using: .utf8)!)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport()
        _ = try? await transport.submitJob(twoImageRequest())

        // The guard must short-circuit before the image upload (or any other request) is issued.
        #expect(box.all.isEmpty)
    }
}
