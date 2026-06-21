import Foundation

/// One typed input to a Comfy Cloud workflow, attached to a `WorkflowRequest`.
public enum WorkflowInput: Sendable {
    /// A text prompt or string parameter.
    case text(String)

    /// An image input attached to the workflow, carrying its raw bytes and MIME type.
    case image(Data, mimeType: String)

    /// A deterministic seed for reproducible sampling.
    case seed(UInt64)
}

struct WorkflowInputNotSupportedError: Error {
    let caseName: String
}
