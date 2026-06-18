//
//  JobHandle.swift
//  ComfySwiftSDK
//
//  Opaque handle for one in-flight Comfy Cloud job. The only thing the
//  app holds across the `submit(_:)` → `events(for:)` boundary, and
//  the only thing the app passes to Story 4.4's `reattach(to:)` to
//  resume an event stream after a network drop.
//
//  The Comfy Cloud `prompt_id` is held only inside `JobHandle` per
//  architecture.md §Format & Data Patterns line 308. The app never
//  parses, stores, or otherwise inspects this value — it just hands
//  the `JobHandle` back to the SDK.
//
//  `reconnectToken` is `internal` and consumed by Story 4.4's
//  `reattach(to:)` API. It is `nil`-permitted in Story 1.5 because
//  reattach is not yet implemented; the field exists in the type so
//  Story 4.4 can land its consumer without a breaking change to
//  `JobHandle`'s memory layout.
//
//  `Hashable` so consumers can store handles as dictionary keys
//  on `GenerationController` (Story 1.8).
//  `Sendable` because the value crosses actor boundaries (`actor`
//  `Transport`, `actor` `WebSocketSession`, `actor` `GenerationController`).
//
//  Story 1.5.
//

import Foundation

/// Opaque handle for one in-flight Comfy Cloud job. Returned by
/// `ComfyCloudClient.submit(_:)` and consumed by `events(for:)`.
public struct JobHandle: Sendable, Hashable {

    /// The opaque Comfy Cloud `prompt_id`. The app never inspects this
    /// value — it is read only by the SDK's internal transport layer.
    public let id: String

    /// Reconnect token used by Story 4.4's `reattach(to:)` API to
    /// resume an existing job's event stream after a network drop.
    /// `nil`-permitted in Story 1.5 because reattach has not yet
    /// landed; Story 4.4 will populate this field from the submit
    /// response (or compute it client-side from `id`, depending on
    /// what Comfy Cloud actually exposes).
    internal let reconnectToken: String?

    /// `internal` initializer so only the SDK's transport layer can
    /// construct `JobHandle` values. Apps receive handles from
    /// `submit(_:)` and pass them back opaquely to `events(for:)`.
    internal init(id: String, reconnectToken: String? = nil) {
        self.id = id
        self.reconnectToken = reconnectToken
    }
}
