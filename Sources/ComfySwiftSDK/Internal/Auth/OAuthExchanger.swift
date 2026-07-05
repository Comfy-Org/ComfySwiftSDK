import Foundation

internal actor OAuthExchanger {

    private struct TokenExchangeDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
            case tokenType    = "token_type"
        }
    }

    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    internal func exchange(
        code: String,
        codeVerifier: String,
        config: OAuthClientConfig = .comfyIOS
    ) async throws -> OAuthTokenResponse {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type",    value: "authorization_code"),
            URLQueryItem(name: "code",          value: code),
            URLQueryItem(name: "redirect_uri",  value: config.redirectURI),
            URLQueryItem(name: "client_id",     value: config.clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Transport.translate(error)
        }

        try Transport.checkStatus(response)

        let dto: TokenExchangeDTO
        do {
            dto = try JSONDecoder().decode(TokenExchangeDTO.self, from: data)
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
