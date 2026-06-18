//
//  JobStatusDTO.swift
//  ComfySwiftSDK
//
//  Wire-format DTOs for the Comfy Cloud WebSocket frame stream and the
//  `GET /api/job/{prompt_id}/status` polling endpoint per the Story 1.5
//  Task 0 research note.
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

/// Wire-format DTO for the polling endpoint
/// `GET /api/prompt/{prompt_id}`. Used by `PollingFallback` (Story 4.4)
/// to read the current job status when the WebSocket transport is
/// unavailable, and by `ReattachCoordinator` (Story 4.4) to fetch a
/// one-shot catch-up snapshot before resuming the event stream.
///
/// Comfy Cloud's status endpoint response shape is not fully
/// documented; observed fields cover: a discriminator `status`
/// string (`queued`/`running`/`success`/`error`/`cancelled`), an
/// optional `progress` bucket (`value`/`max`), and an optional
/// `outputs` mapping from node id to `NodeOutputPayload`. Every
/// field except `status` is optional so the DTO decodes permissively
/// — new fields the server starts emitting should not crash the SDK.
///
/// Story 4.4.
struct JobStatusDTO: Decodable {
    /// Discriminator: `"queued"`, `"running"`, `"success"`, `"error"`,
    /// or `"cancelled"`. The SDK treats any unknown value as
    /// `"running"` (conservative — keep polling).
    let status: String

    /// Optional progress bucket. Present while `status == "running"`.
    let progress: ProgressBody?

    /// Optional phase hint. Comfy Cloud may emit the currently-
    /// executing node id in one of several fields; try all of them.
    let node: String?

    /// Optional outputs bucket keyed by node id. Present on terminal
    /// `status == "success"`.
    let outputs: [String: NodeOutputPayload]?

    /// Optional error diagnostics. Present on terminal `status == "error"`.
    let error: ErrorBody?

    struct ProgressBody: Decodable {
        let value: Double?
        let max: Double?
    }

    struct ErrorBody: Decodable {
        let message: String?
        let nodeType: String?
        let exceptionType: String?
        let exceptionMessage: String?

        enum CodingKeys: String, CodingKey {
            case message
            case nodeType = "node_type"
            case exceptionType = "exception_type"
            case exceptionMessage = "exception_message"
        }
    }

    enum CodingKeys: String, CodingKey {
        case status
        case progress
        case node
        case outputs
        case error
    }
}

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
