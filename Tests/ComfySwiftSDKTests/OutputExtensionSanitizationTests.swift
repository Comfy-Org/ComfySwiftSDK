import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("Output extension sanitization")
struct OutputExtensionSanitizationTests {

    @Test("ordinary extensions pass through, lowercased")
    func passesOrdinaryExtensions() {
        #expect(Transport.sanitizedExtension("png") == "png")
        #expect(Transport.sanitizedExtension("JPEG") == "jpeg")
        #expect(Transport.sanitizedExtension("mp4") == "mp4")
        #expect(Transport.sanitizedExtension("webp") == "webp")
    }

    @Test("path-traversal and slash-bearing extensions collapse to bin")
    func rejectsTraversalAndSlashes() {
        #expect(Transport.sanitizedExtension("../../etc/passwd") == "bin")
        #expect(Transport.sanitizedExtension("..") == "bin")
        #expect(Transport.sanitizedExtension("png/../../x") == "bin")
        #expect(Transport.sanitizedExtension("foo/bar") == "bin")
        #expect(Transport.sanitizedExtension(#"a\b"#) == "bin")
    }

    @Test("empty, dotted, or overlong extensions collapse to bin")
    func rejectsMalformedExtensions() {
        #expect(Transport.sanitizedExtension("") == "bin")
        #expect(Transport.sanitizedExtension("tar.gz") == "bin")            // contains a dot
        #expect(Transport.sanitizedExtension("verylongextension") == "bin") // > 10 chars
        #expect(Transport.sanitizedExtension("png ") == "bin")              // trailing space
    }
}
