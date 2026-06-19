//
//  LoggingPrivacyTests.swift
//  ComfySwiftSDKTests
//
//  NFR-S2 enforcement: credential-free logging.
//
//  The SDK now emits error-level logs via SDKLog for diagnostic purposes.
//  This test suite:
//    1. Verifies that logging EXISTS at the targeted failure paths
//       (relaxed from the old implicit "no logging at all" posture to
//        "logging exists but is credential-free").
//    2. Asserts that no credential sentinel — API key, bearer token, or
//       any recognizable fragment thereof — ever appears in any emitted
//       log message.
//
//  Mechanism: SDKLog.overrideSink(_:) installs a test closure that
//  captures every message the facade would have sent to os.Logger.
//  All assertions run against those captured strings.
//
//  Sentinel values used across the suite — deliberately distinctive so
//  accidental partial matches are impossible:
//    API key:     "sk-SENTINEL-API-KEY-NFR-S2-TEST"
//    Bearer token: "bearer-SENTINEL-OAUTH-TOKEN-NFR-S2-TEST"
//

import Testing
import Foundation
@testable import ComfySwiftSDK

// MARK: - Log capture helper

/// Thread-safe accumulator for SDKLog messages captured during a test.
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

// MARK: - Credential sentinels

/// Sentinel credential values used in the privacy assertions below.
/// These strings are designed so any substring leaking into a log
/// message is unmistakably a credential exposure.
private let sentinelAPIKey    = "sk-SENTINEL-API-KEY-NFR-S2-TEST"
private let sentinelBearer    = "bearer-SENTINEL-OAUTH-TOKEN-NFR-S2-TEST"

/// The fragments we assert must NEVER appear in any log message.
private let credentialSubstrings: [String] = [
    sentinelAPIKey,
    sentinelBearer,
    // Also guard against partial leaks of the key/token values
    "SENTINEL-API-KEY",
    "SENTINEL-OAUTH-TOKEN",
]

// MARK: - Helpers

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

// MARK: - Suite

@Suite("LoggingPrivacy — NFR-S2 credential-free logging", .serialized)
struct LoggingPrivacyTests {

    // MARK: - Transport.translate: POSIX path

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

        // The message must mention the POSIX code, not an auth value
        let combined = messages.joined()
        #expect(combined.contains("POSIX") || combined.contains("posix") || combined.contains("\(ECONNRESET)"),
                "Expected the POSIX code to appear in the log")
    }

    // MARK: - Transport.translate: unknown fallback path

    @Test("Transport.translate unknown fallback emits a log and contains no credential")
    func transport_translate_unknown_logs_and_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        // Use an error type whose description does not contain any sentinel
        struct UnknownTestError: Error {}
        _ = Transport.translate(UnknownTestError())

        let messages = capture.messages
        #expect(!messages.isEmpty, "Expected at least one log from the unknown fallback path")
        assertNoCredential(in: messages)
    }

    // MARK: - SDKLog.wsOutputBuildFailed: no credential in message

    @Test("wsOutputBuildFailed log message never contains API key or bearer token")
    func ws_output_build_failed_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        // Simulate the call site: only ComfyError case + safe jobId reach the log.
        // The underlying error carries a string resembling a credential — the log
        // must never interpolate the underlying error's associated value.
        let poisonedUnderlying = NSError(
            domain: "com.test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: sentinelAPIKey]
        )
        SDKLog.wsOutputBuildFailed(
            error: .network(underlying: poisonedUnderlying),
            jobId: "test-job-abc"
        )

        // The log must not echo back any credential substrings
        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    // MARK: - SDKLog.wsReadLoopError: no credential in message

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

    // MARK: - SDKLog.wsExecutionError: no credential in message

    @Test("wsExecutionError log message never contains API key or bearer token")
    func ws_execution_error_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.wsExecutionError(jobId: "job-xyz")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    // MARK: - SDKLog.pollingGaveUp: no credential in message

    @Test("pollingGaveUp log message never contains API key or bearer token")
    func polling_gave_up_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.pollingGaveUp(error: .authInvalid, jobId: "job-auth")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    // MARK: - SDKLog.pollingOutputAssemblyFailed: no credential in message

    @Test("pollingOutputAssemblyFailed log message never contains API key or bearer token")
    func polling_output_assembly_failed_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.pollingOutputAssemblyFailed(error: .timeout, jobId: "job-to")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    // MARK: - SDKLog.pollingEmptyOutputExhausted: no credential in message

    @Test("pollingEmptyOutputExhausted log message never contains API key or bearer token")
    func polling_empty_output_exhausted_no_credential() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        SDKLog.pollingEmptyOutputExhausted(jobId: "job-eo")

        assertNoCredential(in: capture.messages)
        #expect(!capture.messages.isEmpty)
    }

    // MARK: - Core NFR-S2 sentinel test
    //
    // Drives Transport.translate (the POSIX path) with an error whose
    // NSUserInfo deliberately includes the sentinel key/token as a string,
    // and asserts it never leaks into any log message. This models the
    // worst-case scenario where an underlying error has somehow captured
    // credential material in its userInfo — the SDK must not echo it back.

    @Test("NFR-S2: credential sentinel in error userInfo never leaks into any log message")
    func nfr_s2_credential_in_error_userinfo_never_logged() {
        let capture = LogCapture()
        SDKLog.overrideSink { category, message in capture.record(category: category, message: message) }
        defer { SDKLog.resetSink() }

        // Craft a poisoned NSError whose userInfo embeds both sentinels
        let poisonedError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNRESET),
            userInfo: [
                NSLocalizedDescriptionKey: "auth=\(sentinelAPIKey) token=\(sentinelBearer)"
            ]
        )

        _ = Transport.translate(poisonedError)

        // Some logs will have been emitted — assert none carry the sentinels
        let messages = capture.messages
        #expect(!messages.isEmpty, "Expected POSIX translation to log something")
        assertNoCredential(in: messages)
    }

    // MARK: - Sink reset isolation

    @Test("SDKLog sink is nil between tests (isolation check)")
    func sink_is_nil_by_default() {
        // If a prior test forgot to call resetSink(), this catches it.
        // We don't install a sink here — just verify nothing is leaking.
        #expect(SDKLog._testSink == nil, "A previous test left the SDKLog sink installed")
    }
}
