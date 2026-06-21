import Foundation

final class TestURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

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

    static func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: config)
    }

    static let executionMutex = NSLock()

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
