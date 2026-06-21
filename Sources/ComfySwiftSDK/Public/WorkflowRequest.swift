import Foundation

/// A submission to `ComfyCloudClient.submit(_:)`, carrying the workflow JSON and a typed input list.
public struct WorkflowRequest: @unchecked Sendable {

    /// The ComfyUI API-format workflow graph, serialized verbatim and posted to Comfy Cloud without validation or modification.
    public let workflowJSON: [String: Any]

    /// Typed inputs the SDK translates into the wire format expected by Comfy Cloud.
    public let inputs: [WorkflowInput]

    /// Extra data forwarded to the ComfyUI execution environment, where partner nodes read `api_key_comfy_org` or `auth_token_comfy_org` to authenticate.
    public let extraData: [String: Any]?

    public init(
        workflowJSON: [String: Any],
        inputs: [WorkflowInput] = [],
        extraData: [String: Any]? = nil
    ) {
        self.workflowJSON = workflowJSON
        self.inputs = inputs
        self.extraData = extraData
    }
}
