import Foundation

/// Runs `produce`, then enforces the credential-injection contract shared by every
/// authenticated request and the WebSocket handshake:
///   - empty result             -> ComfyError.authInvalid
///   - producer throws ComfyError -> rethrown unchanged
///   - producer throws CancellationError -> surfaced as ComfyError.cancelled
///   - producer throws anything else -> ComfyError.authInvalid
/// This is the single source of truth; do not inline this shape at call sites.
///
/// Cooperative cancellation is deliberately NOT collapsed into `.authInvalid`: doing so
/// would misreport a cancelled auth/token fetch as a rejected credential and, on the
/// `.oauthRefreshable` path, make `withAuthRetry` trigger spurious refresh/retry work
/// instead of propagating the cancellation. This mirrors `ComfyAuth.mapStoreError`, which
/// surfaces cancellation as `.cancelled` for the same reason.
internal func normalizeToken(
    _ produce: () async throws -> String
) async throws -> String {
    do {
        let token = try await produce()
        guard !token.isEmpty else { throw ComfyError.authInvalid }
        return token
    } catch let e as ComfyError {
        throw e
    } catch is CancellationError {
        throw ComfyError.cancelled
    } catch {
        throw ComfyError.authInvalid
    }
}
