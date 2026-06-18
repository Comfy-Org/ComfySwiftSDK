//
//  ComfyError.swift
//  ComfySwiftSDK
//
//  The SDK's exhaustive error taxonomy. Every error thrown out of any
//  public method on `ComfyCloudClient` (or yielded inside a `JobEvent.failed`)
//  is one of these eleven cases. The app's `ErrorPresentation` (Epic 4
//  Story 4.1) translates these domain identifiers into user-facing copy
//  via a `message(for: ComfyError) -> UserFacingError` mapping table.
//
//  Contract surface (architecture.md §Cross-Component Dependencies line 228):
//    - Adding a case is a non-breaking change.
//    - Removing or renaming a case is a breaking change.
//    - The Epic 4 Story 4.1 expansion from the Story 1.5 wired cases to the
//      full ten-case taxonomy is non-breaking because Story 1.5 declares all
//      cases up front; Story 4.1 only adds the internal `throw` paths.
//
//  Naming rule (architecture.md §Naming Patterns line 255):
//    Cases are domain-named, NEVER transport-named. `.authInvalid`, never
//    `.http401`. `.network(underlying:)`, never `.urlSessionFailed`.
//
//  Privacy contract (NFR-S2 / NFR-S3 / FR26):
//    No case may carry the API key. No case may carry raw HTTP response
//    bodies. No case may carry the workflow JSON. No case may carry
//    `localizedDescription` strings or any user-facing text. The whole
//    point of routing through `ErrorPresentation` at the view-model
//    boundary is to keep user copy out of the SDK; if the SDK starts
//    embedding strings, that abstraction collapses.
//
//  Story 1.5.
//

import Foundation

/// The SDK's exhaustive error taxonomy. Every error thrown out of
/// `ComfyCloudClient` is one of these cases. The app's `ErrorPresentation`
/// translates each case into a `UserFacingError` for display.
public enum ComfyError: Error, Sendable {

    /// Authentication failed. The supplied API key was rejected by the
    /// server (HTTP 401 / 403). The app should clear the key from the
    /// Keychain and re-prompt for entry.
    ///
    /// Epic 1 — wired (Transport status-code translator).
    case authInvalid

    /// Authentication credentials were once valid but have expired. The
    /// app should re-prompt for a fresh key. Distinct from `.authInvalid`
    /// so the UI can show a different message ("Your key expired" vs
    /// "Your key was rejected").
    ///
    /// Epic 4 — stub. Not thrown by Story 1.5 code paths; Epic 4 Story 4.1
    /// will wire it via a server-side discriminator on the 401 response.
    case authExpired

    /// A transport-level network failure not otherwise classified.
    /// Carries the underlying `URLError` (or any other `Error` produced
    /// during transport) so a debugger can inspect the original cause.
    /// User-facing copy never includes the underlying value.
    ///
    /// Epic 1 — wired (Transport / WebSocketSession).
    case network(underlying: Error)

    /// The device has no network connectivity. Distinct from `.network`
    /// so the UI can render a "you're offline" state instead of a generic
    /// failure. Maps from `URLError.notConnectedToInternet`,
    /// `.networkConnectionLost`, and `.dataNotAllowed`.
    ///
    /// Epic 1 — wired (Transport status-code translator).
    case offline

    /// The request did not complete within the SDK's timeout window.
    /// Maps from `URLError.timedOut`. The "taking longer than expected"
    /// UI from Epic 4 Story 4.6 is a separate, longer threshold; this
    /// case fires only when the URLSession itself gives up.
    ///
    /// Epic 1 — wired (Transport status-code translator).
    case timeout

    /// The server rejected the workflow with a structured reason.
    /// Carries a typed `ServerRejectionReason` so the UI can recover
    /// based on the specific failure (e.g., "model unavailable —
    /// pick a different one"). Distinct from `.network` because the
    /// server actively responded; the request was not lost in transit.
    ///
    /// Epic 4 — stub. Story 4.1 will split HTTP 4xx (other than 401/403)
    /// into specific `ServerRejectionReason` cases.
    case serverRejected(reason: ServerRejectionReason)

    /// The server's content filter rejected the prompt or output. The
    /// UI should show a "content filtered" message and allow the user
    /// to edit the prompt. Distinct from `.serverRejected` so the
    /// recovery action is "edit prompt", not "pick a different model".
    ///
    /// Epic 4 — stub.
    case contentFiltered

    /// The job started but failed during a specific phase. The `phase`
    /// label is a transport-agnostic string like `"sampling"` or
    /// `"vae_decode"` (never a raw Comfy Cloud node name). Distinct
    /// from `.serverRejected` because submission succeeded.
    ///
    /// Epic 4 — stub.
    case jobFailed(phase: String)

    /// The server rate-limited the request. If `retryAfter` is non-nil,
    /// the UI should respect it (e.g., disable the Generate button until
    /// the deadline). If nil, the UI should use a sensible default.
    ///
    /// Epic 4 — stub. Story 4.1 will populate `retryAfter` from the
    /// `Retry-After` HTTP header.
    case rateLimited(retryAfter: TimeInterval?)

    /// The job was cancelled cooperatively by the consumer task (the
    /// app called `Task.cancel()` on the iterator over `events(for:)`).
    /// The SDK fires a best-effort `POST /api/queue {"delete":[id]}`
    /// to free server resources, then yields exactly one `.cancelled`
    /// event before closing the stream. The FR23 path.
    ///
    /// Epic 1 — wired (FR23 cancel path).
    case cancelled

    /// An error escaped every other case mapper. Carries the underlying
    /// `Error` for debugging. Includes decoding errors (which are
    /// almost always programmer errors — DTO/wire-format mismatch),
    /// and any unforeseen `URLError` subtype.
    ///
    /// Epic 1 — wired (Transport / WebSocketSession fallback).
    case unknown(underlying: Error)
}

/// Typed payload for `ComfyError.serverRejected(reason:)`. Each case is a
/// distinct user-facing recovery story; Epic 4 Story 4.1 will populate
/// these from server response discriminators.
public enum ServerRejectionReason: Sendable {
    /// The server could not parse the workflow JSON. Recovery: the app's
    /// `ModelCatalog.workflowBuilder` produced an invalid graph; this is
    /// always a programmer error.
    case malformedWorkflow

    /// The requested model is not available right now (e.g., temporarily
    /// disabled, removed, or behind a feature flag the user lacks).
    /// Recovery: pick a different model.
    case modelUnavailable

    /// The user has hit their plan's quota for this billing period.
    /// Recovery: wait for the quota window to roll over, or upgrade.
    case quotaExceeded

    /// A server-side rejection that doesn't fit any of the above. The
    /// associated `String` is a stable machine identifier (NEVER a
    /// user-facing sentence) so future code can pattern-match on it.
    case other(String)
}
