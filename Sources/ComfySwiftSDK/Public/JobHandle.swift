import Foundation

/// Opaque handle for one in-flight Comfy Cloud job. Returned by `ComfyCloudClient.submit(_:)` and consumed by `events(for:)`.
public struct JobHandle: Sendable, Hashable {

    /// The opaque Comfy Cloud job id, read only by the SDK's transport layer.
    public let id: String

    internal init(id: String) {
        self.id = id
    }
}
