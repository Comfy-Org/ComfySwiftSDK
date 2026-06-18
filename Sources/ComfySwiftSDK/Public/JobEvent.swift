//
//  JobEvent.swift
//  ComfySwiftSDK
//
//  The SDK's lifecycle event stream type. Every frame yielded by
//  `ComfyCloudClient.events(for:)` is one of these six cases.
//
//  This enum is the source of truth for the FR21 UI state machine
//  (PRD line 504): queued → generating → finalizing → complete / failed.
//  Story 1.8's `GenerationController.GenerationState` mirrors it 1:1
//  (architecture.md line 191) so the view layer never sees a transport
//  detail.
//
//  Transport details NEVER leak out (architecture.md §Naming Patterns
//  line 256). There are no `.connecting`, `.disconnected`, or
//  `.reconnecting` cases — the WebSocket↔polling hand-off is entirely
//  internal to the SDK. The Story 4.4 `reattach(to:)` API will resume
//  an existing job's stream after a network drop, but it does so by
//  yielding the same six lifecycle cases — the consumer cannot tell
//  whether a frame came from the original WebSocket connection or a
//  reattach.
//
//  Fraction clamping (AC3): the SDK clamps `progress.fraction` into
//  `[0.0, 1.0]` before yielding. This is defense in depth — a malformed
//  server frame must not propagate `1.5` or `-0.2` into the UI ticker.
//
//  Phase labels (AC3): `phase` is a short transport-agnostic string
//  like `"queued"`, `"sampling"`, `"vae_decode"`. NEVER a raw Comfy
//  Cloud node name (e.g. `"KSampler"` or `"VAEDecode"` would leak the
//  workflow graph into the UI).
//
//  `Sendable`: consumers iterate this enum across actor boundaries
//  (`GenerationController` is itself an actor per architecture.md
//  line 191), so all six cases must be Sendable. The `.complete` and
//  `.failed` payloads are Sendable by their own declarations.
//
//  Story 1.5.
//

import Foundation

/// One frame in the lifecycle of an in-flight Comfy Cloud job.
/// `ComfyCloudClient.events(for:)` returns an `AsyncThrowingStream<JobEvent, Error>`
/// that yields these cases in order until terminating with one of
/// `.complete`, `.failed`, or `.cancelled`.
public enum JobEvent: Sendable {

    /// The job has been accepted by Comfy Cloud and is waiting in the
    /// execution queue. Yielded at most once per job, before any
    /// `.progress` events.
    case queued

    /// The job is actively executing. `fraction` is in `[0.0, 1.0]`
    /// (clamped by the SDK before yielding). `phase` is a short
    /// transport-agnostic label like `"queued"`, `"sampling"`, or
    /// `"vae_decode"` — never a raw Comfy Cloud node name.
    /// May be yielded zero or many times.
    case progress(fraction: Double, phase: String)

    /// The job has finished generating and the SDK is downloading the
    /// output media. Distinct from `.progress` so the UI can show a
    /// "saving" indicator. Yielded at most once per job, after all
    /// `.progress` events and before `.complete`.
    case finalizing

    /// The job finished successfully. The associated `WorkflowOutput`
    /// carries the output media (already streamed to disk for video,
    /// inline `Data` for image), the wall-clock duration, and the
    /// originating job id. Terminal — the stream finishes after this.
    case complete(WorkflowOutput)

    /// The job failed. The associated `ComfyError` is one of the
    /// eleven cases in the SDK's error taxonomy. Terminal — the
    /// stream finishes after this.
    case failed(ComfyError)

    /// The job was cancelled cooperatively by the consumer task
    /// (the consumer called `Task.cancel()` on the iterator). The
    /// SDK fires a best-effort cancel request to Comfy Cloud and
    /// yields exactly one `.cancelled` event before closing the
    /// stream. Terminal.
    case cancelled
}
