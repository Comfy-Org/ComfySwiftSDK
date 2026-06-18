//
//  WorkflowInput.swift
//  ComfySwiftSDK
//
//  Typed inputs the app attaches to a `WorkflowRequest`.
//
//  IMPORTANT — current Story 1.5 wire-format reality:
//    Comfy Cloud's `POST /api/prompt` endpoint accepts a single opaque
//    workflow graph and nothing else; there is no parallel `inputs`
//    channel on the wire. Concretely:
//      - `.text(_)` is **advisory only** in Story 1.5: the actual prompt
//        text must be embedded inside the workflow JSON's `CLIPTextEncode`
//        node by the app's `ModelCatalog.workflowBuilder` (Epic 2). The
//        SDK accepts `.text` cases for forward-compat (so `submit(_:)`
//        call sites are stable across stories) but does **not** put them
//        on the wire.
//      - `.seed(_)` is **advisory only** in Story 1.5 for the same reason:
//        the seed lives inside the workflow's `KSampler` node.
//      - `.image(_, mimeType:)` is **rejected at submit time** with a
//        `ComfyError.unknown(underlying: WorkflowInputNotSupportedError)`
//        because supporting it requires the `POST /api/upload/image`
//        endpoint and a follow-up workflow rewrite — both Story 3.4
//        territory. The SDK fails loudly rather than silently dropping
//        image bytes (which the cursor-reviews adversarial pass flagged
//        as a deceptive contract).
//
//    All three cases stay declared in Story 1.5 so the public surface is
//    stable when Story 3.4 wires real image upload (architecture.md
//    §Cross-Component Dependencies line 228 — adding wiring is
//    non-breaking; renaming/removing a case is breaking). The doc
//    comments here are the contract; if you add a new case, you also
//    update the validator inside `Transport.submitJob`.
//
//  Story 1.5 (cursor-reviews fix #1: dead-weight inputs honesty).
//

import Foundation

/// One typed input to a Comfy Cloud workflow. Attached to a
/// `WorkflowRequest` and validated by the SDK at the `submit(_:)`
/// boundary.
///
/// Story 1.5 wire-format reality: `.text` and `.seed` are advisory only
/// (the workflow JSON already encodes them); `.image` is rejected at
/// submit time and lands in Story 3.4. See the file header for the full
/// rationale.
public enum WorkflowInput: Sendable {
    /// A text prompt or string parameter. **Advisory only in Story 1.5**
    /// — the actual prompt text must be embedded inside the workflow
    /// JSON's `CLIPTextEncode` node by the app's
    /// `ModelCatalog.workflowBuilder`. The SDK accepts this case for
    /// forward-compat but does not transmit it as a separate channel.
    case text(String)

    /// An input image. `Data` is the raw bytes (typically JPEG after
    /// the Story 3.3 `ImageProcessing.heicToJpegDownscale` pipeline);
    /// `mimeType` is the MIME type the SDK forwards to Comfy Cloud.
    ///
    /// **Story 1.5 will reject this case at submit time** with a
    /// `ComfyError.unknown(underlying: WorkflowInputNotSupportedError)`.
    /// Image upload requires the `POST /api/upload/image` endpoint plus
    /// a workflow-graph rewrite that swaps a `LoadImage` node onto the
    /// uploaded filename — both Story 3.4 territory.
    case image(Data, mimeType: String)

    /// A deterministic seed for reproducible sampling. **Advisory only
    /// in Story 1.5** — the seed must be set on the workflow JSON's
    /// `KSampler` node by the app's `ModelCatalog.workflowBuilder`.
    /// `UInt64` matches the width Comfy Cloud's `KSampler.seed` field
    /// expects when image upload + reproducible flows land in Story 3.x.
    case seed(UInt64)
}

/// Sentinel error thrown by `Transport.submitJob` when the request
/// includes a `WorkflowInput` case the SDK does not yet wire to the
/// wire format. Wrapped in `ComfyError.unknown(underlying:)` so the
/// public taxonomy stays stable; Story 3.4 removes the throw site for
/// the `.image` case.
///
/// The error carries no API key, no workflow JSON, and no user-facing
/// strings — only a stable machine identifier (`caseName`) per the
/// NFR-S2 / FR26 contract on `ComfyError`.
struct WorkflowInputNotSupportedError: Error {
    /// Stable machine identifier of the rejected case (e.g. `"image"`).
    /// Future Epic 4 `ErrorPresentation` will pattern-match on this.
    let caseName: String
}
