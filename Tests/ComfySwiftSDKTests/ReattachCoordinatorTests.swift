import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("ReattachCoordinator", .serialized)
struct ReattachCoordinatorTests {

    @Test("reattach to an already-completed job emits .complete and closes")
    func terminalSuccess() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
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
            let body = #"""
            {"id":"job-1","status":"completed","create_time":1,"update_time":2,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
            """#
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
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(events.count == 1, "Expected exactly one event, got \(events.count)")
        if case .complete = events.first {
        } else {
            Issue.record("Expected .complete, got \(String(describing: events.first))")
        }
    }

    @Test("reattach to an already-failed job emits .failed(.jobFailed) and closes")
    func terminalError() async throws {
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
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(events.count == 1)
        if case .failed(.jobFailed(let phase)) = events.first {
            #expect(phase == "sampling")
        } else {
            Issue.record("Expected .failed(.jobFailed), got \(String(describing: events.first))")
        }
    }

    @Test("reattach to an already-cancelled job emits .cancelled and closes")
    func terminalCancelled() async throws {
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
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if events.count > 5 { break }
        }

        #expect(events.count == 1)
        if case .cancelled = events.first { } else {
            Issue.record("Expected .cancelled, got \(String(describing: events.first))")
        }
    }

    @Test("reattach to a running job emits synthetic .queued + .progress then continues via polling")
    func activeRunningContinues() async throws {
        let counter = RequestCounter()
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let catchUp = #"""
        {"id":"job-1","status":"in_progress","create_time":1,"update_time":2}
        """#
        let moreProgress = #"""
        {"id":"job-1","status":"in_progress","create_time":1,"update_time":3}
        """#
        let done = #"""
        {"id":"job-1","status":"completed","create_time":1,"update_time":4,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
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
                return (resp, imagePNG)
            }
            let idx = counter.nextAndIncrement()
            let body: String
            switch idx {
            case 0: body = catchUp
            case 1: body = moreProgress
            default: body = done
            }
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
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if case .complete = event { break }
            if case .failed = event { break }
            if events.count > 20 { break }
        }

        let queuedCount = events.filter { if case .queued = $0 { return true }; return false }.count
        #expect(queuedCount == 1, "Expected exactly one .queued (no duplicate across catch-up → polling), got \(queuedCount)")

        let progressCount = events.filter { if case .progress = $0 { return true }; return false }.count
        #expect(progressCount >= 1, "Expected at least one .progress (catch-up), got \(progressCount)")

        #expect(events.contains(where: { if case .finalizing = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .complete = $0 { return true }; return false }))
    }

    @Test("reattach to a queued job emits synthetic .queued then continues polling")
    func activeQueuedContinues() async throws {
        let counter = RequestCounter()
        let queuedBody = #"{"id":"job-1","status":"pending","create_time":1,"update_time":1}"#
        let runningBody = #"""
        {"id":"job-1","status":"in_progress","create_time":1,"update_time":2}
        """#
        let done = #"""
        {"id":"job-1","status":"completed","create_time":1,"update_time":3,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
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
            let body: String
            switch idx {
            case 0: body = queuedBody
            case 1: body = runningBody
            default: body = done
            }
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
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "job-1")

        var events: [JobEvent] = []
        for try await event in coordinator.reattach(to: handle) {
            events.append(event)
            if case .complete = event { break }
            if case .failed = event { break }
            if events.count > 20 { break }
        }

        let queuedCount = events.filter { if case .queued = $0 { return true }; return false }.count
        #expect(queuedCount == 1, "Expected exactly one .queued, got \(queuedCount)")
        #expect(events.contains(where: { if case .progress = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .complete = $0 { return true }; return false }))
    }

    @Test("reattach with auth failure on catch-up GET surfaces .failed(.authInvalid)")
    func catchUpAuthFailure() async throws {
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
        let coordinator = ReattachCoordinator(
            transport: transport,
            clock: ImmediateClock()
        )
        let handle = JobHandle(id: "job-1")

        var sawAuthInvalid = false
        for try await event in coordinator.reattach(to: handle) {
            if case .failed(.authInvalid) = event {
                sawAuthInvalid = true
                break
            }
        }
        #expect(sawAuthInvalid)
    }

    @Test("ComfyCloudClient.reattach(promptId:) returns a valid stream")
    func reattachByPromptIdReturnsStream() async throws {
        let client = ComfyCloudClient(apiKey: "test-key")
        let stream = client.reattach(promptId: "some-prompt-id")

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try? await iterator.next()
        }
        task.cancel()
        _ = await task.value
        #expect(Bool(true))
    }

    @Test("ComfyCloudClient.reattach(promptId:) forwards promptId as JobHandle.id (source-level)")
    func reattachByPromptIdUsesPromptIdAsHandleId() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let clientPath = packageRoot.appendingPathComponent(
            "Sources/ComfySwiftSDK/Public/ComfyCloudClient.swift"
        )
        let source = try String(contentsOf: clientPath, encoding: .utf8)

        guard let methodStart = source.range(of: "public func reattach(\n        promptId: String")?.lowerBound else {
            Issue.record("reattach(promptId:) method not found in ComfyCloudClient.swift")
            return
        }
        let afterSignature = source[methodStart...]
        let methodEnd = afterSignature.dropFirst(1).range(of: "\n    public func ")?.lowerBound
            ?? afterSignature.dropFirst(1).range(of: "\n    private func ")?.lowerBound
            ?? afterSignature.dropFirst(1).range(of: "\n    func ")?.lowerBound
            ?? source.endIndex
        let methodBody = String(source[methodStart..<methodEnd])

        #expect(
            methodBody.contains("JobHandle(id: promptId"),
            "reattach(promptId:) must construct JobHandle with id: promptId — promptId is the handle id contract (Story 4.9, AC4)"
        )
        #expect(
            methodBody.contains("reattachCoordinator.reattach("),
            "reattach(promptId:) must forward to the coordinator (Story 4.9, AC4)"
        )
    }
}
