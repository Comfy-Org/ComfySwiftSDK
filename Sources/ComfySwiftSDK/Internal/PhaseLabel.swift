import Foundation

/// The SDK's single, consumer-facing progress vocabulary surfaced via
/// `JobEvent.progress(phase:)`.
///
/// Both transports derive the phase for the same job from an executing node's
/// class/type name, so they MUST share one taxonomy — the live WebSocket path
/// and the HTTP polling fallback (plus `ReattachCoordinator` and
/// `PollingFallback.derivePhase`) all route through this function. Keeping the
/// mapping in one place is what stops a new node class or a renamed phase from
/// silently diverging between transports.
enum PhaseLabel {
    /// Maps a node's class/type name to its progress phase label.
    static func forNode(_ node: String) -> String {
        let lower = node.lowercased()
        if lower.contains("ksampler") || lower.contains("sampler") {
            return "sampling"
        }
        if lower.contains("vae") {
            return "vae_decode"
        }
        if lower.contains("clip") || lower.contains("encode") {
            return "encoding"
        }
        if lower.contains("save") || lower.contains("preview") {
            return "saving"
        }
        if lower == "queued" {
            return "queued"
        }
        return "executing"
    }
}
