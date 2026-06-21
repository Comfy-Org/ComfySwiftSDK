import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Output fetch transient retry", .serialized)
struct OutputFetchTransientRetryTests {

    @Test("succeeds on first attempt when no error")
    func noErrorPassThrough() async throws {
        var callCount = 0
        let result = try await PollingFallback.withTransientRetry {
            callCount += 1
            return 42
        }
        #expect(result == 42)
        #expect(callCount == 1)
    }

    @Test("retries and succeeds after one transient error")
    func retriesAfterOneTransientError() async throws {
        var callCount = 0
        let result: Int = try await PollingFallback.withTransientRetry {
            callCount += 1
            if callCount < 2 {
                let posixErr = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
                throw Transport.translate(posixErr)
            }
            return 99
        }
        #expect(result == 99)
        #expect(callCount == 2)
    }

    @Test("retries and succeeds after two transient errors")
    func retriesAfterTwoTransientErrors() async throws {
        var callCount = 0
        let result: Int = try await PollingFallback.withTransientRetry {
            callCount += 1
            if callCount < 3 {
                throw ComfyError.network(underlying: URLError(.networkConnectionLost))
            }
            return 7
        }
        #expect(result == 7)
        #expect(callCount == 3)
    }

    @Test("surfaces failure after exhausting all attempts")
    func exhaustedRetriesSurfaces() async throws {
        var callCount = 0
        var caughtTransient = false
        do {
            let _: Int = try await PollingFallback.withTransientRetry {
                callCount += 1
                throw ComfyError.offline
            }
        } catch ComfyError.offline {
            caughtTransient = true
        }
        #expect(caughtTransient)
        #expect(callCount == PollingFallback.outputFetchMaxAttempts)
    }

    @Test("non-transient error propagates immediately without retry")
    func nonTransientDoesNotRetry() async throws {
        var callCount = 0
        var caughtAuthInvalid = false
        do {
            let _: Int = try await PollingFallback.withTransientRetry {
                callCount += 1
                throw ComfyError.authInvalid
            }
        } catch ComfyError.authInvalid {
            caughtAuthInvalid = true
        }
        #expect(caughtAuthInvalid)
        #expect(callCount == 1)
    }

    @Test("jobFailed error propagates immediately without retry")
    func jobFailedDoesNotRetry() async throws {
        var callCount = 0
        var caughtJobFailed = false
        do {
            let _: Int = try await PollingFallback.withTransientRetry {
                callCount += 1
                throw ComfyError.jobFailed(phase: "sampling")
            }
        } catch ComfyError.jobFailed {
            caughtJobFailed = true
        }
        #expect(caughtJobFailed)
        #expect(callCount == 1)
    }

    @Test("buildOutput retries transient error on downloadView and succeeds")
    func buildOutputRetryOnTransientDownload() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let viewCallCount = RequestCounter()

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            guard path.contains("/api/view") else {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data())
            }
            let idx = viewCallCount.nextAndIncrement()
            if idx == 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png"])!
            return (resp, imagePNG)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )

        let dto = JobDetailResponse(
            id: "job-99",
            status: "completed",
            outputs: [
                "9": .init(
                    images: [OutputFileRef(filename: "out.png", subfolder: "", type: "output")],
                    gifs: nil,
                    videos: nil,
                    audio: nil
                )
            ],
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )

        let output = try await PollingFallback.buildOutput(
            from: dto,
            transport: transport,
            startTime: Date(),
            jobId: "job-99"
        )
        #expect(!output.files.isEmpty)
        #expect(viewCallCount.nextAndIncrement() == 2)
    }

    @Test("buildOutput surfaces non-transient error as failure")
    func buildOutputNonTransientFails() async throws {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }
        defer { TestURLProtocol.uninstall() }

        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("bad-key")
        )

        let dto = JobDetailResponse(
            id: "job-100",
            status: "completed",
            outputs: [
                "9": .init(
                    images: [OutputFileRef(filename: "out.png", subfolder: "", type: "output")],
                    gifs: nil,
                    videos: nil,
                    audio: nil
                )
            ],
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )

        var caughtAuthInvalid = false
        do {
            _ = try await PollingFallback.buildOutput(
                from: dto,
                transport: transport,
                startTime: Date(),
                jobId: "job-100"
            )
        } catch ComfyError.authInvalid {
            caughtAuthInvalid = true
        }
        #expect(caughtAuthInvalid)
    }

    @Test("polling success path retries transient view error and yields .complete")
    func pollingSuccessRetryTransientView() async throws {
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let statusCalls = RequestCounter()
        let viewCalls = RequestCounter()

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/view") {
                let idx = viewCalls.nextAndIncrement()
                if idx == 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
                }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])!
                return (resp, imagePNG)
            }
            let idx = statusCalls.nextAndIncrement()
            let body: String
            if idx == 0 {
                body = #"{"id":"job-retry","status":"pending","create_time":1,"update_time":1}"#
            } else {
                body = #"""
                {"id":"job-retry","status":"completed","create_time":1,"update_time":2,"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}
                """#
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
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
            jobId: "job-retry",
            startTime: Date(),
            clock: ImmediateClock()
        )

        var sawComplete = false
        var sawFailed = false
        for try await event in polling.eventStream() {
            if case .complete = event { sawComplete = true; break }
            if case .failed = event { sawFailed = true; break }
            if case .cancelled = event { break }
        }

        #expect(sawComplete, "Expected .complete but got failed=\(sawFailed)")
        #expect(!sawFailed)
    }

    @Test("execution_success with empty buffered refs yields .failed (EmptyOutputError)")
    func emptyOutputSurfacesAsFailed() async throws {
        let transport = Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
        let dto = JobDetailResponse(
            id: "job-empty",
            status: "completed",
            outputs: nil,
            executionError: nil,
            createTime: nil,
            updateTime: nil
        )

        var caughtEmpty = false
        do {
            _ = try await PollingFallback.buildOutput(
                from: dto,
                transport: transport,
                startTime: Date(),
                jobId: "job-empty"
            )
        } catch ComfyError.unknown(let underlying) where underlying is EmptyOutputError {
            caughtEmpty = true
        }
        #expect(caughtEmpty)
    }

    @Test("isTransient(.cancelled) returns false")
    func cancelledIsNotTransient() {
        #expect(!PollingFallback.isTransient(.cancelled))
    }

    @Test("isTransient(.authInvalid) returns false")
    func authInvalidIsNotTransient() {
        #expect(!PollingFallback.isTransient(.authInvalid))
    }

    @Test("isTransient(.jobFailed) returns false")
    func jobFailedIsNotTransient() {
        #expect(!PollingFallback.isTransient(.jobFailed(phase: "vae_decode")))
    }

    @Test("POSIX ECONNRESET translates to a transient ComfyError")
    func econnresetIsTransient() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let translated = Transport.translate(err)
        #expect(PollingFallback.isTransient(translated))
    }
}
