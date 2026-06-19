//
//  SDKLog.swift
//  ComfySwiftSDK
//
//  Minimal credential-free logging facade for SDK internals.
//
//  Design constraints (NFR-S2 / NFR-S3):
//    - NEVER log the API key, any OAuth bearer/access token, refresh
//      token, Authorization header value, X-API-Key header value,
//      request body, response body, output bytes, or a whole URLRequest /
//      URLResponse / raw Error object (those may carry header material).
//    - Log ONLY error classification: ComfyError case name, POSIX
//      domain+code, HTTP status code, and jobId.
//    - All interpolated values are marked `.public` only when they are
//      known-safe classification fields. Everything else stays `.private`
//      (the os_log default).
//
//  Platform: iOS 17+ / macOS 14+ — os.Logger is available without guards.
//
//  Injectable sink: in production the facade writes to os.Logger. In test
//  builds callers can swap in a `SDKLogSink` closure via
//  `SDKLog.overrideSink(_:)` to capture emitted strings and assert on
//  them — the same string that would have gone to os.Logger is passed to
//  the closure instead. Override is process-global; tests must reset it.
//

import os
import Foundation

// MARK: - Injectable sink

/// A closure that receives the category and message for each log call
/// when a test override is active. Used by the NFR-S2 privacy test.
internal typealias SDKLogSink = @Sendable (_ category: String, _ message: String) -> Void

// MARK: - SDKLog

/// Credential-free logging facade. One `Logger` per category, all under
/// the `org.comfy.ComfySwiftSDK` subsystem. Callers use the static
/// convenience methods; the category-specific loggers live here so the
/// subsystem string is defined in exactly one place.
internal enum SDKLog {

    // MARK: os.Logger instances

    private static let transportLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "transport"
    )
    private static let websocketLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "websocket"
    )
    private static let pollingLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "polling"
    )

    // MARK: Test override

    /// Process-global override installed by tests. When non-nil, log
    /// calls write to this closure INSTEAD OF os.Logger, so tests can
    /// capture the message strings and assert on them.
    ///
    /// Reset to `nil` between tests. Access is intentionally not
    /// lock-guarded — tests are expected to install/uninstall on a
    /// single thread (before and after each test body), and the
    /// overhead of a lock on every log call in production is undesirable.
    nonisolated(unsafe) internal static var _testSink: SDKLogSink?

    /// Install a test sink. Every subsequent log call routes to `sink`
    /// instead of os.Logger until `resetSink()` is called.
    internal static func overrideSink(_ sink: @escaping SDKLogSink) {
        _testSink = sink
    }

    /// Remove the test sink and restore os.Logger routing.
    internal static func resetSink() {
        _testSink = nil
    }

    // MARK: - Internal emit helpers

    private static func emit(
        category: String,
        logger: Logger,
        _ message: @escaping @autoclosure () -> String
    ) {
        let msg = message()
        if let sink = _testSink {
            sink(category, msg)
            return
        }
        // In production, build the message and emit at .error level.
        // The string is assembled in the caller (not via os_log string
        // interpolation) so credential-free-ness is enforced at the
        // call sites in this file rather than scattered across the SDK.
        logger.error("\(msg, privacy: .public)")
    }

    // MARK: - Transport category

    /// Log a POSIX socket-drop translation in `Transport.translate(_:)`.
    /// Safe fields: POSIX domain (constant string) + code (Int).
    internal static func transportPOSIXTranslated(code: Int32) {
        emit(
            category: "transport",
            logger: transportLogger,
            "translate: POSIX socket-drop posix=\(code)"
        )
    }

    /// Log the `.unknown` fallback in `Transport.translate(_:)`.
    /// Safe field: the Swift type name of the error (no message/body).
    internal static func transportUnknownFallback(errorType: String) {
        emit(
            category: "transport",
            logger: transportLogger,
            "translate: unknown error type=\(errorType)"
        )
    }

    // MARK: - WebSocket category

    /// Log a failure in the `execution_success` output-build catch block.
    /// Safe fields: ComfyError case name + jobId.
    internal static func wsOutputBuildFailed(error: ComfyError, jobId: String) {
        emit(
            category: "websocket",
            logger: websocketLogger,
            "ws.output-build failed: \(comfyErrorCaseName(error)) job=\(jobId)"
        )
    }

    /// Log the transient→polling handoff decision in the read-loop catch.
    /// Safe fields: ComfyError case name + jobId + handoff decision label.
    internal static func wsReadLoopError(
        error: ComfyError,
        jobId: String,
        handingOffToPolling: Bool
    ) {
        let decision = handingOffToPolling ? "→polling-handoff" : "→failed"
        emit(
            category: "websocket",
            logger: websocketLogger,
            "ws.read-loop error: \(comfyErrorCaseName(error)) job=\(jobId) decision=\(decision)"
        )
    }

    /// Log an `execution_error` frame received from the server.
    /// Safe fields: jobId only — the exceptionType is server-provided
    /// and may contain model/prompt context, so it is omitted.
    internal static func wsExecutionError(jobId: String) {
        emit(
            category: "websocket",
            logger: websocketLogger,
            "ws.execution-error frame received job=\(jobId)"
        )
    }

    // MARK: - Polling category

    /// Log a terminal/output-assembly failure in `PollingFallback`.
    /// Safe fields: ComfyError case name + jobId.
    internal static func pollingOutputAssemblyFailed(error: ComfyError, jobId: String) {
        emit(
            category: "polling",
            logger: pollingLogger,
            "polling.output-assembly failed: \(comfyErrorCaseName(error)) job=\(jobId)"
        )
    }

    /// Log when the polling loop gives up on a non-transient error.
    /// Safe fields: ComfyError case name + jobId.
    internal static func pollingGaveUp(error: ComfyError, jobId: String) {
        emit(
            category: "polling",
            logger: pollingLogger,
            "polling.gave-up: \(comfyErrorCaseName(error)) job=\(jobId)"
        )
    }

    /// Log when the eventually-consistent success retry budget is exhausted.
    /// Safe field: jobId.
    internal static func pollingEmptyOutputExhausted(jobId: String) {
        emit(
            category: "polling",
            logger: pollingLogger,
            "polling.empty-output-exhausted job=\(jobId)"
        )
    }

    // MARK: - Safe ComfyError case name

    /// Return the case name of a `ComfyError` — never the associated
    /// value (which may carry an underlying Error that contains
    /// credential or response material). This is the only ComfyError
    /// field that is safe to log.
    private static func comfyErrorCaseName(_ error: ComfyError) -> String {
        switch error {
        case .authInvalid:        return "ComfyError.authInvalid"
        case .authExpired:        return "ComfyError.authExpired"
        case .network:            return "ComfyError.network"
        case .offline:            return "ComfyError.offline"
        case .timeout:            return "ComfyError.timeout"
        case .serverRejected:     return "ComfyError.serverRejected"
        case .contentFiltered:    return "ComfyError.contentFiltered"
        case .jobFailed:          return "ComfyError.jobFailed"
        case .rateLimited:        return "ComfyError.rateLimited"
        case .cancelled:          return "ComfyError.cancelled"
        case .unknown:            return "ComfyError.unknown"
        }
    }
}
