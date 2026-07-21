import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("WebSocketSession.reifyFrame — frame body reification")
struct ReifyFrameTests {

    /// Decodes `json` the way the read loop does: as a frame envelope, handing
    /// the `data` body to `reifyFrame`.
    private func reify<T: Decodable>(_ json: String, as: T.Type = T.self) throws -> T? {
        let envelope = try JSONDecoder().decode(
            WebSocketFrameEnvelope.self,
            from: Data(json.utf8)
        )
        return WebSocketSession.reifyFrame(envelope.data)
    }

    @Test("Object body reifies into a typed executed frame")
    func objectBodyReifies() throws {
        let executed: ExecutedFrameData? = try reify("""
        {"type":"executed","data":{"node":"9","prompt_id":"abc",
         "output":{"images":[{"filename":"a.png","subfolder":"","type":"output"}]}}}
        """)

        #expect(executed?.node == "9")
        #expect(executed?.promptId == "abc")
        #expect(executed?.output?.images?.count == 1)
        #expect(executed?.output?.images?.first?.filename == "a.png")
    }

    @Test("Execution-error object body reifies into a typed error frame")
    func errorBodyReifies() throws {
        let decoded: ExecutionErrorFrameData? = try reify("""
        {"type":"execution_error","data":{"prompt_id":"abc","node_type":"KSampler",
         "exception_type":"ValueError","exception_message":"boom"}}
        """)

        #expect(decoded?.exceptionType == "ValueError")
        #expect(decoded?.exceptionMessage == "boom")
        #expect(decoded?.nodeType == "KSampler")
    }

    /// Regression: `JSONSerialization.data(withJSONObject:)` raises an
    /// uncatchable ObjC `NSInvalidArgumentException` for top-level scalars,
    /// which `try?` cannot intercept. A malformed frame must fall through to
    /// `nil` rather than crash the client.
    @Test(
        "Scalar body returns nil instead of crashing",
        arguments: [
            #"{"type":"executed","data":42}"#,
            #"{"type":"executed","data":3.5}"#,
            #"{"type":"executed","data":"boom"}"#,
            #"{"type":"executed","data":true}"#,
            #"{"type":"executed","data":null}"#
        ]
    )
    func scalarBodyReturnsNil(json: String) throws {
        let executed: ExecutedFrameData? = try reify(json)
        #expect(executed == nil)
    }

    @Test("Absent body returns nil")
    func absentBodyReturnsNil() throws {
        let executed: ExecutedFrameData? = try reify(#"{"type":"executed"}"#)
        #expect(executed == nil)
    }

    @Test("Body of the wrong shape returns nil")
    func mismatchedBodyReturnsNil() throws {
        // A JSON array is a valid top-level object for JSONSerialization but
        // cannot decode into ExecutedFrameData's keyed container.
        let executed: ExecutedFrameData? = try reify(#"{"type":"executed","data":[1,2,3]}"#)
        #expect(executed == nil)
    }
}
