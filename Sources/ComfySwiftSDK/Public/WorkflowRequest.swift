//
//  WorkflowRequest.swift
//  ComfySwiftSDK
//
//  The request the app passes to `ComfyCloudClient.submit(_:)`. The SDK
//  does not interpret `workflowJSON` — that is the app's
//  `ModelCatalog.workflowBuilder` territory (architecture.md line 196).
//  The SDK only serializes the dictionary via
//  `JSONSerialization.data(withJSONObject:)` and posts it to Comfy Cloud.
//
//  `@unchecked Sendable` rationale:
//    `[String: Any]` is not `Sendable` by default — `Any` provides no
//    isolation guarantees. But `WorkflowRequest` is value-typed, the
//    SDK takes ownership of the dictionary at the `submit(_:)` call
//    site, and the dictionary is never mutated after construction. The
//    cross-actor passing is therefore safe in practice. This is the
//    canonical Swift workaround for the Foundation `[String: Any]` JSON
//    shape — see also `JSONSerialization.data(withJSONObject:)`, which
//    accepts the same value-type-of-Any-dict shape.
//
//    `@unchecked Sendable` is permitted only on this type. Every other
//    type in the SDK is naturally `Sendable` or is an actor.
//
//  Story 1.5.
//

import Foundation

/// A submission to `ComfyCloudClient.submit(_:)`. Carries the workflow
/// JSON (opaque to the SDK) and a typed input list.
public struct WorkflowRequest: @unchecked Sendable {

    /// The ComfyUI API-format workflow graph. Built by the app's
    /// `ModelCatalog.workflowBuilder` closures (Epic 2 Story 2.1).
    /// The SDK does not validate, parse, or modify this dictionary —
    /// it is serialized verbatim via
    /// `JSONSerialization.data(withJSONObject:)` and posted to
    /// Comfy Cloud.
    public let workflowJSON: [String: Any]

    /// Typed inputs the app wants attached to the request. The SDK
    /// translates these into the wire format expected by Comfy Cloud.
    /// In Epic 1 only `.text` is exercised; `.image` and `.seed` are
    /// declared for future stories.
    public let inputs: [WorkflowInput]

    /// Extra data sent alongside the prompt. Comfy Cloud forwards this
    /// to the ComfyUI execution environment. Partner/API-tier nodes
    /// read `api_key_comfy_org` (legacy mode, caller-supplied) or
    /// `auth_token_comfy_org` (OAuth mode, injected by the SDK at
    /// submit time — BE-1420) from this dictionary to authenticate
    /// with their backend services.
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
