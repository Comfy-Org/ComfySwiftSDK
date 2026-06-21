import Testing
import Foundation
@testable import ComfySwiftSDK

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(category: String, message: String)] = []

    func record(category: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        _entries.append((category: category, message: message))
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return _entries.map { $0.message }
    }

    var entries: [(category: String, message: String)] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }
}

private let sentinelAPIKey    = "sk-SENTINEL-API-KEY-NFR-S2-TEST"
private let sentinelBearer    = "bearer-SENTINEL-OAUTH-TOKEN-NFR-S2-TEST"

private let credentialSubstrings: [String] = [
    sentinelAPIKey,
    sentinelBearer,
    "SENTINEL-API-KEY",
    "SENTINEL-OAUTH-TOKEN",
]

private func assertNoCredential(in messages: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for message in messages {
        for fragment in credentialSubstrings {
            if message.contains(fragment) {
                Issue.record(
                    "NFR-S2 VIOLATION: credential fragment '\(fragment)' found in log message: \(message)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}

@Suite("LoggingPrivacy — NFR-S2 credential-free logging", .serialized)
struct LoggingPrivacyTests {

    @Test("Transport.translate POSIX path emits a log and contains no credential")
    func transport_translate_posix_logs_and_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        let posixErr = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        _ = Transport.translate(posixErr)

        let messages = capture.messages
        #expect(!messages.isEmpty, "Expected at least one log from the POSIX translation path")
        assertNoCredential(in: messages)

        let combined = messages.joined()
        #expect(combined.contains("POSIX") || combined.contains("posix") || combined.contains("\(ECONNRESET)"),
                "Expected the POSIX code to appear in the log")
    }

    @Test("Transport.translate unknown fallback emits a log and contains no credential")
    func transport_translate_unknown_logs_and_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        struct UnknownTestError: Error {}
        _ = Transport.translate(UnknownTestError())

        let messages = capture.messages
        #expect(!messages.isEmpty, "Expected at least one log from the unknown fallback path")
        assertNoCredential(in: messages)
    }

    @Test("wsOutputBuildFailed log message never contains API key or bearer token")
    func ws_output_build_failed_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        let poisonedUnderlying = NSError(
            domain: "com.test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: sentinelAPIKey]
        )
        SDKLog.wsOutputBuildFailed(
            error: .network(underlying: poisonedUnderlying),
            jobId: "test-job-abc"
        )

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    @Test("wsReadLoopError log message never contains API key or bearer token")
    func ws_read_loop_error_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.wsReadLoopError(
            error: .offline,
            jobId: "job-abc",
            handingOffToPolling: true
        )

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)

        let combined = capture.messages.joined()
        #expect(combined.contains("polling"))
    }

    @Test("wsExecutionError log message never contains API key or bearer token")
    func ws_execution_error_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.wsExecutionError(jobId: "job-xyz")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    @Test("pollingGaveUp log message never contains API key or bearer token")
    func polling_gave_up_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.pollingGaveUp(error: .authInvalid, jobId: "job-auth")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    @Test("pollingOutputAssemblyFailed log message never contains API key or bearer token")
    func polling_output_assembly_failed_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.pollingOutputAssemblyFailed(error: .timeout, jobId: "job-to")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    @Test("pollingEmptyOutputExhausted log message never contains API key or bearer token")
    func polling_empty_output_exhausted_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.pollingEmptyOutputExhausted(jobId: "job-eo")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    @Test("NFR-S2: credential sentinel in error userInfo never leaks into any log message")
    func nfr_s2_credential_in_error_userinfo_never_logged() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        let poisonedError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNRESET),
            userInfo: [
                NSLocalizedDescriptionKey: "auth=\(sentinelAPIKey) token=\(sentinelBearer)"
            ]
        )

        _ = Transport.translate(poisonedError)

        let messages = capture.messages
        #expect(!messages.isEmpty, "Expected POSIX translation to log something")
        assertNoCredential(in: messages)
    }

    @Test("SDKLog sink is nil between tests (isolation check)")
    func sink_is_nil_by_default() {
        #expect(SDKLog._testSink == nil, "A previous test left the SDKLog sink installed")
    }
}
