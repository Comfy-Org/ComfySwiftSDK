import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Named image inputs — node-targeted uploads", .serialized)
struct NamedImageInputTests {

    /// Captures every request the transport issues, plus a drained copy of the body,
    /// and hands back scripted upload names / a submit success so `submitJob` runs end to end.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var uploadCount = 0
        private var _promptBody: [String: Any]?

        /// The decoded `prompt` object from the `api/prompt` submit request (the patched workflow).
        var submittedWorkflow: [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return _promptBody
        }

        func install() {
            TestURLProtocol.install { [self] request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("api/upload/image") {
                    lock.lock()
                    uploadCount += 1
                    let name = "uploaded-\(uploadCount).png"
                    lock.unlock()
                    return (Self.jsonResponse(request), #"{"name": "\#(name)"}"#.data(using: .utf8)!)
                }
                if path.hasSuffix("api/prompt") {
                    if let body = Self.drainBody(request),
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let prompt = json["prompt"] as? [String: Any] {
                        lock.lock(); _promptBody = prompt; lock.unlock()
                    }
                    return (Self.jsonResponse(request), #"{"prompt_id": "job-123"}"#.data(using: .utf8)!)
                }
                return (Self.jsonResponse(request), "{}".data(using: .utf8)!)
            }
        }

        private static func jsonResponse(_ request: URLRequest) -> HTTPURLResponse {
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
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
    }

    private func makeTransport() -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
    }

    private func imageInput(_ node: String) -> WorkflowInput {
        .namedImage(Data([0x01]), mimeType: "image/png", nodeId: node)
    }

    /// Reads `workflow[nodeId].inputs["image"]`.
    private func imageName(in workflow: [String: Any]?, nodeId: String) -> String? {
        (workflow?[nodeId] as? [String: Any])?["inputs"].flatMap { $0 as? [String: Any] }?["image"] as? String
    }

    @Test("two namedImage inputs patch their own nodes — no cross-contamination")
    func twoNamedImagesTargetDistinctNodes() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        let request = WorkflowRequest(
            workflowJSON: [
                "10": ["class_type": "LoadImage", "inputs": ["image": ""]],
                "20": ["class_type": "LoadImage", "inputs": ["image": ""]]
            ],
            inputs: [imageInput("10"), imageInput("20")]
        )

        _ = try await makeTransport().submitJob(request)

        let workflow = harness.submittedWorkflow
        let first = imageName(in: workflow, nodeId: "10")
        let second = imageName(in: workflow, nodeId: "20")
        // Each loader carries its own uploaded name; they must differ (last-write-wins regression guard).
        #expect(first == "uploaded-1.png")
        #expect(second == "uploaded-2.png")
        #expect(first != second)
    }

    @Test("namedImage patches a LoadImageMask node (class_type-agnostic)")
    func namedImageTargetsLoadImageMask() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        let request = WorkflowRequest(
            workflowJSON: [
                "5": ["class_type": "LoadImageMask", "inputs": ["image": "", "channel": "red"]]
            ],
            inputs: [imageInput("5")]
        )

        _ = try await makeTransport().submitJob(request)

        #expect(imageName(in: harness.submittedWorkflow, nodeId: "5") == "uploaded-1.png")
        // Non-image inputs on the targeted node are left untouched.
        let inputs = (harness.submittedWorkflow?["5"] as? [String: Any])?["inputs"] as? [String: Any]
        #expect(inputs?["channel"] as? String == "red")
    }

    @Test("existing .image input still blanket-patches every LoadImage node")
    func imageInputStillBlanketPatches() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        let request = WorkflowRequest(
            workflowJSON: [
                "1": ["class_type": "LoadImage", "inputs": ["image": ""]],
                "2": ["class_type": "LoadImage", "inputs": ["image": ""]],
                "3": ["class_type": "KSampler", "inputs": ["seed": 0]]
            ],
            inputs: [.image(Data([0xAA]), mimeType: "image/png")]
        )

        _ = try await makeTransport().submitJob(request)

        let workflow = harness.submittedWorkflow
        #expect(imageName(in: workflow, nodeId: "1") == "uploaded-1.png")
        #expect(imageName(in: workflow, nodeId: "2") == "uploaded-1.png")
        // Non-LoadImage nodes are not touched.
        let sampler = (workflow?["3"] as? [String: Any])?["inputs"] as? [String: Any]
        #expect(sampler?["seed"] as? Int == 0)
        #expect(sampler?["image"] == nil)
    }

    @Test("namedImage with an unknown nodeId fails fast rather than dropping the binding")
    func namedImageWithMissingNodeThrows() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        let request = WorkflowRequest(
            workflowJSON: [
                "7": ["class_type": "LoadImage", "inputs": ["image": "original.png"]]
            ],
            inputs: [imageInput("999")]
        )

        // An explicit but unresolvable target must surface an error, not silently submit the
        // job against the original image.
        await #expect(throws: ComfyError.self) {
            _ = try await self.makeTransport().submitJob(request)
        }
        // No prompt was submitted; the unrelated node was never touched.
        #expect(harness.submittedWorkflow == nil)
    }

    @Test("namedImage targeting a non-image node (no image input) fails fast")
    func namedImageTargetingNonImageNodeThrows() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        let request = WorkflowRequest(
            workflowJSON: [
                "3": ["class_type": "KSampler", "inputs": ["seed": 0]]
            ],
            inputs: [imageInput("3")]
        )

        // A node with an `inputs` dict but no `image` key must not get a bogus `image` injected.
        await #expect(throws: ComfyError.self) {
            _ = try await self.makeTransport().submitJob(request)
        }
        #expect(harness.submittedWorkflow == nil)
    }

    @Test("two namedImage inputs on the same node are rejected (silent-clobber guard)")
    func duplicateNamedImageNodeThrows() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        let request = WorkflowRequest(
            workflowJSON: [
                "10": ["class_type": "LoadImage", "inputs": ["image": ""]]
            ],
            inputs: [imageInput("10"), imageInput("10")]
        )

        await #expect(throws: ComfyError.self) {
            _ = try await self.makeTransport().submitJob(request)
        }
        // Rejected before any upload — no wasted work, nothing submitted.
        #expect(harness.uploadCount == 0)
        #expect(harness.submittedWorkflow == nil)
    }

    @Test("namedImage wins over a blanket .image patch on the same LoadImage node")
    func namedImageBeatsBlanketPatchOnSharedNode() async throws {
        let harness = Harness()
        harness.install()
        defer { TestURLProtocol.uninstall() }

        // Input order puts .image last; the fix must still let the node-targeted binding win,
        // because patch order (targeted last) — not input order — decides the final image.
        let request = WorkflowRequest(
            workflowJSON: [
                "10": ["class_type": "LoadImage", "inputs": ["image": ""]],
                "20": ["class_type": "LoadImage", "inputs": ["image": ""]]
            ],
            inputs: [imageInput("10"), .image(Data([0xAA]), mimeType: "image/png")]
        )

        _ = try await makeTransport().submitJob(request)

        let workflow = harness.submittedWorkflow
        // Blanket .image is uploaded/applied first (uploaded-1.png → every LoadImage), then the
        // node-targeted upload (uploaded-2.png) overwrites node 10. Node 10 keeps the named
        // binding; node 20 keeps the blanket one.
        #expect(imageName(in: workflow, nodeId: "10") == "uploaded-2.png")
        #expect(imageName(in: workflow, nodeId: "20") == "uploaded-1.png")
    }
}
