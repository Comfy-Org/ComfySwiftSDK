import Foundation

/// Wire-format DTO for `GET /api/jobs/{job_id}` (`getJobDetail`) — the
/// `/api/jobs` replacement for the legacy `GET /api/prompt/{prompt_id}`
/// status read. `prompt_id` and `job_id` are the same identifier, so
/// `JobHandle.id` is already the correct path parameter.
///
/// This is the foundation for the migration tracked in issue #12: the
/// type and its status normalization are unit-tested here; the cutover
/// that wires it into `Transport` / `PollingFallback` / `ReattachCoordinator`
/// is a follow-up that needs a staging smoke test.
struct JobDetailDTO: Decodable {
    /// `"pending" | "in_progress" | "completed" | "failed" | "cancelled"`.
    let status: String

    /// The job id (same value as `JobHandle.id` / the legacy `prompt_id`).
    let id: String?

    /// Node-keyed outputs. The contract describes this as the "Full
    /// outputs object from ComfyUI", i.e. the same shape the legacy
    /// status read returns — so the `/api/view` byte-fetch path is
    /// unchanged. Present only for terminal (`completed`) states.
    let outputs: [String: NodeOutputPayload]?

    /// Structured error detail, present for `failed` jobs.
    let executionError: ExecutionErrorBody?

    enum CodingKeys: String, CodingKey {
        case status
        case id
        case outputs
        case executionError = "execution_error"
    }

    struct ExecutionErrorBody: Decodable {
        let nodeType: String?
        let exceptionType: String?
        let exceptionMessage: String?

        enum CodingKeys: String, CodingKey {
            case nodeType = "node_type"
            case exceptionType = "exception_type"
            case exceptionMessage = "exception_message"
        }
    }

    /// Maps the `/api/jobs` status vocabulary onto the legacy status
    /// strings the SDK's state machine already understands
    /// (`queued` / `running` / `success` / `error` / `cancelled`), so the
    /// cutover is a drop-in for the existing `PollingFallback` and
    /// `ReattachCoordinator` switch statements. An unrecognized status
    /// maps to `running` — the conservative choice that keeps polling.
    var legacyEquivalentStatus: String {
        switch status.lowercased() {
        case "pending": return "queued"
        case "in_progress": return "running"
        case "completed": return "success"
        case "failed": return "error"
        case "cancelled": return "cancelled"
        default: return "running"
        }
    }
}

/// Wire-format DTO for `POST /api/jobs/{job_id}/cancel` (`cancelJob`) —
/// the `/api/jobs` replacement for the deprecated `POST /api/queue`
/// `{"delete":[id]}` cancel. Cancellation is best-effort; the SDK yields
/// `.cancelled` regardless of the boolean.
struct JobCancelDTO: Decodable {
    let cancelled: Bool
}
