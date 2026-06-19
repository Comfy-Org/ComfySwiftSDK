//
//  JobStatusDTO.swift
//  ComfySwiftSDK
//
//  Wire-format DTOs for the Comfy Cloud WebSocket frame stream and the
//  `GET /api/jobs/{job_id}` polling endpoint.
//
//  Comfy Cloud's WebSocket sends JSON text frames in the shape
//  `{"type": "<discriminator>", "data": {...}}` where the discriminators
//  are: `status`, `notification`, `execution_start`, `executing`,
//  `progress`, `executed`, `execution_success`, `execution_error`,
//  `execution_interrupted`. Binary frames carry preview images and are
//  ignored by Story 1.5 (the previews fall under future Epic 4 work).
//
//  The DTO model below decodes only the `type` discriminator at the
//  top level, then peels off `data` per case so unknown frames degrade
//  gracefully — Comfy Cloud may add new frame types and the SDK should
//  not crash.
//
//  Story 1.5.
//

import Foundation

/// Top-level WebSocket frame envelope. The `data` field's exact shape
/// varies by `type`, so the SDK decodes the discriminator first and
/// then re-decodes the data dictionary into the matching per-frame DTO.
struct WebSocketFrameEnvelope: Decodable {
    let type: String
    let data: AnyDecodable?
}

/// Per-frame data shape for `type == "progress"`. Comfy Cloud emits
/// `value` (current step) and `max` (total steps); the SDK computes
/// `fraction = value / max` and clamps to `[0, 1]`.
struct ProgressFrameData: Decodable {
    let value: Double?
    let max: Double?
    let node: String?
    let promptId: String?

    enum CodingKeys: String, CodingKey {
        case value
        case max
        case node
        case promptId = "prompt_id"
    }
}

/// Per-frame data shape for `type == "executing"`. The `node` field
/// names the currently-executing node id; `nil` indicates the workflow
/// has finished. The SDK uses this to derive a coarse phase label
/// for `JobEvent.progress(phase:)`.
struct ExecutingFrameData: Decodable {
    let node: String?
    let promptId: String?

    enum CodingKeys: String, CodingKey {
        case node
        case promptId = "prompt_id"
    }
}

/// Per-frame data shape for `type == "executed"`. Comfy Cloud emits
/// one of these per output-producing node, with the per-node output
/// payload (image / video / audio) under `output`.
struct ExecutedFrameData: Decodable {
    let node: String?
    let promptId: String?
    let output: NodeOutputPayload?

    enum CodingKeys: String, CodingKey {
        case node
        case promptId = "prompt_id"
        case output
    }
}

/// Per-frame data shape for `type == "execution_success"`.
/// Marks the workflow as complete (final terminal frame for the
/// success path).
struct ExecutionSuccessFrameData: Decodable {
    let promptId: String?

    enum CodingKeys: String, CodingKey {
        case promptId = "prompt_id"
    }
}

/// Per-frame data shape for `type == "execution_error"`.
/// Carries a node id and an exception type/message; Story 1.5 routes
/// every execution error through `ComfyError.network(underlying:)` and
/// Story 4.1 will split this into `.jobFailed(phase:)` /
/// `.contentFiltered` / etc.
struct ExecutionErrorFrameData: Decodable {
    let promptId: String?
    let nodeType: String?
    let exceptionType: String?
    let exceptionMessage: String?

    enum CodingKeys: String, CodingKey {
        case promptId = "prompt_id"
        case nodeType = "node_type"
        case exceptionType = "exception_type"
        case exceptionMessage = "exception_message"
    }
}

/// Per-node output payload as emitted inside an `executed` frame.
/// Comfy Cloud's `executed` frame carries node-typed output buckets
/// — `images`, `videos`, `audio`, etc. Story 1.5 only consumes
/// `images` and `videos`; future stories may add more.
struct NodeOutputPayload: Decodable {
    let images: [OutputFileRef]?
    let gifs: [OutputFileRef]?
    let videos: [OutputFileRef]?
    let audio: [OutputFileRef]?
}

/// One output media artifact reference. Comfy Cloud delivers media
/// via the `(filename, subfolder, type)` tuple — the actual bytes
/// are fetched separately via `GET /api/view?filename=...&subfolder=...&type=...`.
struct OutputFileRef: Decodable {
    let filename: String
    let subfolder: String
    let type: String
}

/// Structured execution error from `GET /api/jobs/{job_id}`.
/// Present on terminal `status == "failed"` responses when the server
/// has structured diagnostics. Maps to the `ExecutionError` schema
/// in the ingest OpenAPI spec.
///
/// Named `JobDetailExecutionError` to avoid shadowing the
/// `JobExecutionError: Error` sentinel used by `WebSocketSession`
/// (which has a different purpose — wrapping WS frame errors for
/// the `ComfyError.unknown` path). This type is a pure Decodable DTO;
/// it is never thrown.
///
/// Required fields per spec: `node_id`, `node_type`, `exception_message`,
/// `exception_type`, `traceback`, `current_inputs`, `current_outputs`.
/// All are decoded permissively (optional in Swift) so a partial
/// server response does not crash decoding.
struct JobDetailExecutionError: Decodable {
    let nodeId: String?
    let nodeType: String?
    let exceptionMessage: String?
    let exceptionType: String?
    let traceback: [String]?

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case nodeType = "node_type"
        case exceptionMessage = "exception_message"
        case exceptionType = "exception_type"
        case traceback
    }
}

/// Wire-format DTO for the job-status polling endpoint
/// `GET /api/jobs/{job_id}`. Used by `PollingFallback` (Story 4.4)
/// to read the current job status when the WebSocket transport is
/// unavailable, and by `ReattachCoordinator` (Story 4.4) to fetch a
/// one-shot catch-up snapshot before resuming the event stream.
///
/// Maps the `JobDetailResponse` schema from the ingest OpenAPI spec.
/// Required fields: `id` (uuid), `status` (enum), `create_time`
/// (int64 ms), `update_time` (int64 ms). Optional fields include
/// `outputs` (present only in terminal states), `execution_error`
/// (present on `failed` with structured diagnostics), and
/// `preview_output`/`outputs_count` (ignored by the SDK).
///
/// Status enum values: `pending`, `in_progress`, `completed`,
/// `failed`, `cancelled`. These differ from the legacy
/// `queued`/`running`/`success`/`error`/`cancelled` values on the
/// tombstoned `/api/prompt/{id}` endpoint.
///
/// Every field except `status` is decoded permissively so the DTO
/// handles partial or forward-compatible server responses without
/// crashing.
///
/// Story 4.4.
struct JobDetailResponse: Decodable {
    /// Unique job identifier (UUID).
    let id: String?

    /// User-friendly job status. Canonical values per the ingest
    /// OpenAPI spec: `"pending"`, `"in_progress"`, `"completed"`,
    /// `"failed"`, `"cancelled"`. The SDK treats any unknown value
    /// as active (conservative — keep polling).
    let status: String

    /// Full outputs object from ComfyUI (only for terminal states).
    /// Keyed by node id; values follow the `NodeOutputPayload` shape.
    let outputs: [String: NodeOutputPayload]?

    /// Structured execution error. Present on `status == "failed"`
    /// when the server has ComfyUI node-level diagnostics.
    let executionError: JobDetailExecutionError?

    /// Job creation timestamp (Unix ms). Decoded for completeness;
    /// not currently used by the SDK's event stream.
    let createTime: Int64?

    /// Last-update timestamp (Unix ms). Decoded for completeness;
    /// not currently used by the SDK's event stream.
    let updateTime: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case outputs
        case executionError = "execution_error"
        case createTime = "create_time"
        case updateTime = "update_time"
    }
}

/// Backward-compatibility typealias. Internal call sites that were
/// written against the old `JobStatusDTO` name compile unchanged;
/// new code should use `JobDetailResponse` directly.
typealias JobStatusDTO = JobDetailResponse

/// Type-erased decodable wrapper. Used for the WebSocket frame
/// envelope's `data` field, which has heterogeneous shape per
/// frame type. Re-encoding the `data` value via `JSONEncoder` and
/// re-decoding it into the per-frame DTO is the cleanest way to
/// handle this in Swift's `Codable`. Confined to the SDK's internal
/// DTO layer.
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if container.decodeNil() {
            value = NSNull()
        } else if let dict = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var result: [String: Any] = [:]
            for key in dict.allKeys {
                let nested = try dict.decode(AnyDecodable.self, forKey: key)
                result[key.stringValue] = nested.value
            }
            value = result
        } else if var array = try? decoder.unkeyedContainer() {
            var result: [Any] = []
            while !array.isAtEnd {
                let nested = try array.decode(AnyDecodable.self)
                result.append(nested.value)
            }
            value = result
        } else {
            value = NSNull()
        }
    }
}

/// Dynamic coding key used by `AnyDecodable` to walk an arbitrary
/// JSON dictionary's keys.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
