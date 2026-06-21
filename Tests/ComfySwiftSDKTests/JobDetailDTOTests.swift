import Foundation
import Testing
@testable import ComfySwiftSDK

@Suite("JobDetailDTO — /api/jobs response decoding and status remap")
struct JobDetailDTOTests {

    private func decode(_ json: String) throws -> JobDetailDTO {
        try JSONDecoder().decode(JobDetailDTO.self, from: Data(json.utf8))
    }

    @Test("completed job decodes status, id, and the unchanged node-keyed outputs")
    func completedWithOutputs() throws {
        let dto = try decode("""
        {
          "id": "abc123",
          "status": "completed",
          "create_time": 1,
          "update_time": 2,
          "outputs": {
            "9": { "images": [ { "filename": "out.png", "subfolder": "", "type": "output" } ] }
          }
        }
        """)
        #expect(dto.status == "completed")
        #expect(dto.id == "abc123")
        #expect(dto.legacyEquivalentStatus == "success")
        #expect(dto.outputs?["9"]?.images?.first?.filename == "out.png")
        #expect(dto.outputs?["9"]?.images?.first?.type == "output")
    }

    @Test("failed job decodes the structured execution_error")
    func failedWithError() throws {
        let dto = try decode("""
        {
          "id": "abc123",
          "status": "failed",
          "create_time": 1,
          "update_time": 2,
          "execution_error": {
            "node_type": "KSampler",
            "exception_type": "RuntimeError",
            "exception_message": "boom"
          }
        }
        """)
        #expect(dto.legacyEquivalentStatus == "error")
        #expect(dto.executionError?.nodeType == "KSampler")
        #expect(dto.executionError?.exceptionType == "RuntimeError")
        #expect(dto.executionError?.exceptionMessage == "boom")
    }

    @Test("the /api/jobs status enum remaps onto the legacy state vocabulary", arguments: [
        ("pending", "queued"),
        ("in_progress", "running"),
        ("completed", "success"),
        ("failed", "error"),
        ("cancelled", "cancelled"),
    ])
    func statusRemap(jobsStatus: String, legacy: String) throws {
        let dto = try decode("""
        { "id": "x", "status": "\(jobsStatus)", "create_time": 1, "update_time": 2 }
        """)
        #expect(dto.status == jobsStatus)
        #expect(dto.legacyEquivalentStatus == legacy)
    }

    @Test("an unrecognized status maps conservatively to running (keep polling)")
    func unknownStatusIsConservative() throws {
        let dto = try decode("""
        { "id": "x", "status": "something_new", "create_time": 1, "update_time": 2 }
        """)
        #expect(dto.legacyEquivalentStatus == "running")
    }

    @Test("non-terminal jobs decode with no outputs and no error")
    func pendingHasNoOutputs() throws {
        let dto = try decode("""
        { "id": "x", "status": "pending", "create_time": 1, "update_time": 2 }
        """)
        #expect(dto.outputs == nil)
        #expect(dto.executionError == nil)
    }

    @Test("JobCancelDTO decodes the {cancelled} response body")
    func cancelResponse() throws {
        let dto = try JSONDecoder().decode(JobCancelDTO.self, from: Data(#"{ "cancelled": true }"#.utf8))
        #expect(dto.cancelled == true)
    }
}
