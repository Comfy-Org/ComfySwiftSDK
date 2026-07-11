import Foundation

internal actor OAuthExchanger {

    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    internal func exchange(
        code: String,
        codeVerifier: String,
        config: OAuthClientConfig = .comfyIOS
    ) async throws -> OAuthTokenResponse {
        let queryItems = [
            URLQueryItem(name: "grant_type",    value: "authorization_code"),
            URLQueryItem(name: "code",          value: code),
            URLQueryItem(name: "redirect_uri",  value: config.redirectURI),
            URLQueryItem(name: "client_id",     value: config.clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        // Exchange lets an HTTP 401 surface as `.authInvalid` (mapAuthInvalidToExpired: false);
        // only the refresh grant remaps it to `.authExpired`.
        return try await OAuthTokenEndpoint.post(
            queryItems: queryItems,
            session: session,
            mapAuthInvalidToExpired: false
        )
    }
}
