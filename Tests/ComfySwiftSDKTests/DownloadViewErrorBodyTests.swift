import Testing
import Foundation
@testable import ComfySwiftSDK

/// Both `api/view` download endpoints must translate a 400/422 error body into a
/// `.serverRejected` reason via `checkBody`. `downloadView` already did; the
/// `download(for:)`-based `downloadViewToTempFile` (used for videos) previously
/// skipped the check and surfaced a generic `.network` error instead. These tests
/// lock in the now-shared behavior across both paths.
@Suite("Download view error-body handling", .serialized)
struct DownloadViewErrorBodyTests {

    private func makeTransport() -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: URL(string: "https://example.test")!,
            credential: .apiKey("test-key")
        )
    }

    private func install400(body: String) {
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, body.data(using: .utf8)!)
        }
    }

    @Test("downloadViewToTempFile maps a 400 error body to .serverRejected (was .network)")
    func tempFileSurfacesServerRejected() async throws {
        install400(body: #"{"error":"the workflow is invalid"}"#)
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport()

        var caught: ServerRejectionReason?
        do {
            _ = try await transport.downloadViewToTempFile(
                filename: "out.mp4",
                subfolder: "",
                type: "output",
                suggestedExtension: "mp4"
            )
        } catch ComfyError.serverRejected(let reason) {
            caught = reason
        }

        guard case .malformedWorkflow = caught else {
            Issue.record("expected .serverRejected(.malformedWorkflow), got \(String(describing: caught))")
            return
        }
    }

    @Test("downloadView still maps the same 400 error body to .serverRejected")
    func inMemorySurfacesServerRejected() async throws {
        install400(body: #"{"error":"the workflow is invalid"}"#)
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport()

        var caught: ServerRejectionReason?
        do {
            _ = try await transport.downloadView(filename: "out.png", subfolder: "", type: "output")
        } catch ComfyError.serverRejected(let reason) {
            caught = reason
        }

        guard case .malformedWorkflow = caught else {
            Issue.record("expected .serverRejected(.malformedWorkflow), got \(String(describing: caught))")
            return
        }
    }

    @Test("downloadViewToTempFile still returns a file on a 200 response")
    func tempFileHappyPathUnchanged() async throws {
        let payload = Data([0x00, 0x01, 0x02, 0x03])
        TestURLProtocol.install { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (resp, payload)
        }
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport()

        let url = try await transport.downloadViewToTempFile(
            filename: "out.mp4",
            subfolder: "",
            type: "output",
            suggestedExtension: "mp4"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "mp4")
        #expect(try Data(contentsOf: url) == payload)
    }
}
