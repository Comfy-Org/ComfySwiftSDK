//
//  TransportPOSIXTranslationTests.swift
//  ComfySwiftSDKTests
//
//  Verifies that POSIX socket-drop error codes are mapped to `.network`
//  (transient) by `Transport.translate(_:)`, so `PollingFallback.isTransient`
//  returns `true` and the polling loop retries rather than surfacing a
//  false failure when the OS kills the socket during backgrounding.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Transport POSIX translation")
struct TransportPOSIXTranslationTests {

    // MARK: - POSIX socket-drop codes → transient

    @Test("ENOTCONN translates to a transient error")
    func enotconn() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("ECONNRESET translates to a transient error")
    func econnreset() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("ECONNABORTED translates to a transient error")
    func econnaborted() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNABORTED))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("ENETDOWN translates to a transient error")
    func enetdown() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("ENETUNREACH translates to a transient error")
    func enetunreach() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENETUNREACH))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("ETIMEDOUT translates to a transient error")
    func etimedout() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("EPIPE translates to a transient error")
    func epipe() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    @Test("EHOSTUNREACH translates to a transient error")
    func ehostunreach() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
    }

    // MARK: - Regression: existing classifications must not shift

    @Test("URLError.cancelled still maps to .cancelled (non-transient)")
    func urlErrorCancelledIsNonTransient() {
        let err = URLError(.cancelled)
        let result = Transport.translate(err)
        #expect(!PollingFallback.isTransient(result))
        if case .cancelled = result { } else {
            Issue.record("Expected .cancelled, got \(result)")
        }
    }

    @Test("URLError.notConnectedToInternet still maps to .offline (transient)")
    func urlErrorOfflineIsTransient() {
        let err = URLError(.notConnectedToInternet)
        let result = Transport.translate(err)
        #expect(PollingFallback.isTransient(result))
        if case .offline = result { } else {
            Issue.record("Expected .offline, got \(result)")
        }
    }

    @Test("ComfyError.jobFailed still maps to non-transient (pass-through)")
    func jobFailedIsNonTransient() {
        let err = ComfyError.jobFailed(phase: "sampling")
        let result = Transport.translate(err)
        #expect(!PollingFallback.isTransient(result))
    }

    @Test("Unknown POSIX code does not become transient")
    func unknownPOSIXCodeIsNotTransient() {
        // EBADF (9) is not in the socket-drop list — should fall through to .unknown
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF))
        let result = Transport.translate(err)
        #expect(!PollingFallback.isTransient(result))
    }
}
