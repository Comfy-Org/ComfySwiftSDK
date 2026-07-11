import Foundation

/// Runs `produce`, then enforces the credential-injection contract shared by every
/// authenticated request and the WebSocket handshake:
///   - empty result            -> ComfyError.authInvalid
///   - producer throws ComfyError -> rethrown unchanged
///   - producer throws anything else -> ComfyError.authInvalid
/// This is the single source of truth; do not inline this shape at call sites.
internal func normalizeToken(
    _ produce: () async throws -> String
) async throws -> String {
    do {
        let token = try await produce()
        guard !token.isEmpty else { throw ComfyError.authInvalid }
        return token
    } catch let e as ComfyError {
        throw e
    } catch {
        throw ComfyError.authInvalid
    }
}
