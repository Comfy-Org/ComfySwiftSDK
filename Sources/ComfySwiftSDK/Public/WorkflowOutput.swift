//
//  WorkflowOutput.swift
//  ComfySwiftSDK
//
//  The payload of `JobEvent.complete(_:)` — what the consumer actually
//  receives when a generation finishes successfully.
//
//  Image vs video delivery (architecture.md §API & Communication line 180):
//    - `.image(Data, mimeType:)` carries the bytes inline. Images are
//      small enough to live in memory; the app's Story 1.9 `MediaStore`
//      writes them straight to disk on receipt.
//    - `.video(url:)` carries a URL pointing at a temp file the SDK has
//      already streamed to disk (`FileManager.default.temporaryDirectory`
//      or the SDK's caches subdirectory). The app's `MediaStore.install(_:)`
//      moves it into Application Support and unlinks the temp. Video in
//      memory is a non-starter; stream→rename is safe and cheap.
//
//  `durationSeconds` semantics:
//    Wall-clock time from `client.submit(_:)` to the `.complete` event,
//    measured by the SDK at the consumption boundary. This is the value
//    Story 1.9's `commitGeneration` persists into
//    `GenerationRecord.durationSeconds`.
//
//  `jobId` is the same opaque string held by the originating
//  `JobHandle.id`. It is included for log correlation only — the app
//  identifies generations by `GenerationRecord.id` (a client-side UUID).
//
//  Story 1.5.
//

import Foundation

/// The successful result of a generation. Yielded inside
/// `JobEvent.complete(_:)`.
public struct WorkflowOutput: Sendable {

    /// The output media. Always at least one element on a successful
    /// completion. Plural to allow future multi-output workflows
    /// (e.g. a controlnet job emitting a primary image + a depth map);
    /// v1 text→image flows produce a single-element array.
    public let files: [OutputFile]

    /// Wall-clock time from `submit(_:)` to `.complete`, in seconds.
    /// The Story 1.9 `commitGeneration` call persists this into
    /// `GenerationRecord.durationSeconds`.
    public let durationSeconds: TimeInterval

    /// The opaque Comfy Cloud job id. Same string as `JobHandle.id`.
    /// Included for log correlation; the app identifies generations
    /// by client-side UUID, not this value.
    public let jobId: String

    public init(files: [OutputFile], durationSeconds: TimeInterval, jobId: String) {
        self.files = files
        self.durationSeconds = durationSeconds
        self.jobId = jobId
    }

    /// One output media artifact from a finished workflow.
    public enum OutputFile: Sendable {
        /// An inline image. The `Data` is the raw bytes (PNG / JPEG /
        /// HEIC depending on workflow); `mimeType` is the
        /// `Content-Type` reported by Comfy Cloud (e.g. `"image/png"`).
        /// Images are small enough to live in memory.
        case image(Data, mimeType: String)

        /// A video file streamed to disk. The URL points at a temp
        /// file in the SDK's caches directory. The app's
        /// `MediaStore.install(_:)` is responsible for moving the file
        /// into Application Support and unlinking the temp. The temp
        /// file is OS-evictable, which is correct for derived data
        /// per architecture.md §Data Architecture line 154.
        case video(url: URL)
    }
}
