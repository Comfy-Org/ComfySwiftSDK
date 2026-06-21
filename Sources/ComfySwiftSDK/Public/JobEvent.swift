import Foundation

/// One frame in the lifecycle of an in-flight Comfy Cloud job, yielded by `ComfyCloudClient.events(for:)`.
public enum JobEvent: Sendable {

    /// The job has been accepted and is waiting in the execution queue.
    case queued

    /// The job is actively executing, with `fraction` in `[0.0, 1.0]` and a transport-agnostic `phase` label.
    case progress(fraction: Double, phase: String)

    /// The job has finished generating and the SDK is downloading the output media.
    case finalizing

    /// The job finished successfully, carrying its output. Terminal.
    case complete(WorkflowOutput)

    /// The job failed, carrying a `ComfyError`. Terminal.
    case failed(ComfyError)

    /// The job was cancelled cooperatively by the consumer task. Terminal.
    case cancelled
}
