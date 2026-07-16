import Foundation

/// Shared token-endpoint POST used by both `OAuthExchanger` (authorization-code
/// grant) and `OAuthTokenRefreshExecutor` (refresh grant). Both flows run the
/// identical five-step dance — form-encode the body, POST as
/// `application/x-www-form-urlencoded`, translate transport errors, check the
/// HTTP status, decode the token DTO, and build `OAuthTokenResponse` — so it
/// lives here once. Callers still own building their own query items (the two
/// grants carry different parameters).
internal enum OAuthTokenEndpoint {

    private struct TokenDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    /// POSTs a form-encoded token request and decodes the standard token response.
    /// - Parameter mapAuthInvalidToExpired: refresh callers pass `true` so an HTTP 401/403
    ///   (`ComfyError.authInvalid` from `Transport.checkStatus`) is remapped to `.authExpired`.
    ///   Exchange callers pass `false`, letting `.authInvalid` propagate unchanged.
    static func post(
        queryItems: [URLQueryItem],
        session: URLSession,
        mapAuthInvalidToExpired: Bool
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let bodyData = formURLEncoded(queryItems).data(using: .utf8) else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        request.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Transport.translate(error)
        }

        do {
            try Transport.checkStatus(response)
        } catch ComfyError.authInvalid where mapAuthInvalidToExpired {
            throw ComfyError.authExpired
        }

        let dto: TokenDTO
        do {
            dto = try JSONDecoder().decode(TokenDTO.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }

        return OAuthTokenResponse(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresIn: dto.expiresIn
        )
    }

    /// Serializes query items as an `application/x-www-form-urlencoded` body.
    /// Unlike `URLComponents.query` (which encodes with `.urlQueryAllowed` and
    /// leaves `+`, `&`, and `=` unescaped), this percent-encodes every character
    /// outside the RFC 3986 unreserved set, so an opaque token value — e.g. a
    /// standard-base64 `code`/`refresh_token` containing `+` — survives the
    /// round-trip instead of being decoded server-side as a space or corrupting
    /// adjacent form fields.
    private static func formURLEncoded(_ items: [URLQueryItem]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        return items
            .map { "\(encode($0.name))=\(encode($0.value ?? ""))" }
            .joined(separator: "&")
    }
}
