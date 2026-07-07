import Foundation

internal actor OAuthTokenRefreshExecutor {

    private struct TokenRefreshDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    internal func refresh(
        using refreshToken: String,
        clientId: String = OAuthClientConfig.comfyIOS.clientId
    ) async throws -> OAuthTokenResponse {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type",    value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            // Per RFC 6749 §6 the refresh grant must carry the same client the token was issued to,
            // so this is threaded from the client's OAuthClientConfig (Transport.oauthConfig) rather
            // than pinned to comfy-ios — a token minted under a custom config would otherwise be
            // rejected on refresh, silently logging the app out at access-token expiry.
            URLQueryItem(name: "client_id",     value: clientId),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let bodyString = body.query, let bodyData = bodyString.data(using: .utf8) else {
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
        } catch ComfyError.authInvalid {
            throw ComfyError.authExpired
        }

        let dto: TokenRefreshDTO
        do {
            dto = try JSONDecoder().decode(TokenRefreshDTO.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }

        return OAuthTokenResponse(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresIn: dto.expiresIn
        )
    }
}
