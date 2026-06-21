import Foundation

/// The successful result of a generation, yielded inside `JobEvent.complete(_:)`.
public struct WorkflowOutput: Sendable {

    /// The output media; always at least one element on a successful completion.
    public let files: [OutputFile]

    /// Wall-clock time from `submit(_:)` to `.complete`, in seconds.
    public let durationSeconds: TimeInterval

    /// The opaque Comfy Cloud job id, the same string as `JobHandle.id`.
    public let jobId: String

    public init(files: [OutputFile], durationSeconds: TimeInterval, jobId: String) {
        self.files = files
        self.durationSeconds = durationSeconds
        self.jobId = jobId
    }

    /// One output media artifact from a finished workflow.
    public enum OutputFile: Sendable {
        /// An inline image, carrying its raw bytes and MIME type.
        case image(Data, mimeType: String)

        /// A video file streamed to disk, given as a temporary file URL.
        case video(url: URL)
    }
}
