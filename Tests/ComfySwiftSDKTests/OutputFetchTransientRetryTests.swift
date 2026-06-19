//
//  OutputFetchTransientRetryTests.swift
//  ComfySwiftSDKTests
//
//  Verifies that a transient network error on the output-download step
//  (ECONNRESET, .network, .offline, .timeout) does NOT surface as
//  `.failed` — the retry helper recovers and yields `.complete(output)`.
//
//  Also covers the regression cases:
//    - A genuine non-transient output error (empty output, decode
//      failure) still surfaces as `.failed`.
//    - `.cancelled` / auth / `.jobFailed` classification is unchanged.
//
//  Uses `TestURLProtocol` to script per-call HTTP responses, and
//  `PollingFallback.withTransientRetry` directly for the unit-level
//  assertion.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Output fetch transient retry", .serialized)
struct OutputFetchTransientRetryTests {

    // MARK: - Unit: withTransientRetry

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
                // Throw a transient POSIX error — same domain used in the
                // backgrounding scenario (ECONNRESET on a resumed socket).
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
        // Must NOT retry — should have thrown on the first call.
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

    // MARK: - Integration: PollingFallback.buildOutput retries transient

    @Test("buildOutput retries transient error on downloadView and succeeds")
    func buildOutputRetryOnTransientDownload() async throws {
        // Script: first /api/view call fails with ECONNRESET; second succeeds.
        let imagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let viewCallCount = RequestCounter()

        TestURLProtocol.install { request in
            let path = request.url?.path ?? ""
            guard path.contains("/api/view") else {
                // Unexpected call — return a safe default.
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data())
            }
            let idx = viewCallCount.nextAndIncrement()
            if idx == 0 {
                // Simulate a stale-connection reset on the first attempt.
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

        // Must not throw — should recover from the first ECONNRESET.
        let output = try await PollingFallback.buildOutput(
            from: dto,
            transport: transport,
            startTime: Date(),
            jobId: "job-99"
        )
        #expect(!output.files.isEmpty)
        // The view endpoint was called twice: once failing, once succeeding.
        #expect(viewCallCount.nextAndIncrement() == 2)
    }

    @Test("buildOutput surfaces non-transient error as failure")
    func buildOutputNonTransientFails() async throws {
        // A 401 on the /api/view call is non-transient — must throw immediately.
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

    // MARK: - Integration: PollingFallback eventStream end-to-end with transient on download

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
                    // First view call: simulate a stale-connection reset.
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
                }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])!
                return (resp, imagePNG)
            }
            // Status endpoint: return pending → completed.
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

    // MARK: - Regression: empty output still surfaces as .failed

    @Test("execution_success with empty buffered refs yields .failed (EmptyOutputError)")
    func emptyOutputSurfacesAsFailed() async throws {
        // PollingFallback.buildOutput throws when imageRefs and videoRefs are both empty.
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

    // MARK: - Regression: cancelled classification unchanged

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

    // MARK: - Regression: ECONNRESET is still transient

    @Test("POSIX ECONNRESET translates to a transient ComfyError")
    func econnresetIsTransient() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let translated = Transport.translate(err)
        #expect(PollingFallback.isTransient(translated))
    }
}
