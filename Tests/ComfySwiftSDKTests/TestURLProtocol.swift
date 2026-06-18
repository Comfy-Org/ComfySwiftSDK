//
//  TestURLProtocol.swift
//  ComfySwiftSDKTests
//
//  Stub `URLProtocol` that lets tests register per-path JSON or error
//  responses for a `Transport`-owned `URLSession`. Used by Story 4.4
//  tests to drive `PollingFallback` and `ReattachCoordinator` without
//  touching the network.
//
//  Story 4.4.
//

import Foundation

/// A stub URL protocol. Tests register a handler closure that returns
/// a `(HTTPURLResponse, Data)` tuple for a given `URLRequest` — the
/// protocol intercepts every request routed through a session that
/// was configured with `[TestURLProtocol.self]` in `protocolClasses`.
final class TestURLProtocol: URLProtocol, @unchecked Sendable {

    /// Response handler registered by the current test. Set to `nil`
    /// between tests to catch leaks.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Global lock guarding `handler` — multiple concurrent polls
    /// may land inside `startLoading` on different queues.
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Build a `URLSession` that routes every request through
    /// `TestURLProtocol`. Call at the top of each test and pass into
    /// `Transport.init(session:...)`.
    static func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Global mutex held across `install(_:)` / `uninstall()` so
    /// Swift Testing suites serialize their use of the shared
    /// `handler`. The built-in `.serialized` trait only serializes
    /// within a single suite; different suites still run in
    /// parallel. Holding this mutex across the test body ensures
    /// that only one suite at a time mutates `handler`.
    static let executionMutex = NSLock()

    /// Install a handler and return an unregister closure that tests
    /// can `defer` to clean up.
    static func install(_ h: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        executionMutex.lock()
        lock.lock()
        handler = h
        lock.unlock()
    }

    static func uninstall() {
        lock.lock()
        handler = nil
        lock.unlock()
        executionMutex.unlock()
    }
}
