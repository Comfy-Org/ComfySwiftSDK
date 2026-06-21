import Foundation

internal actor OAuthMetadataFetcher {

    internal struct OAuthServerMetadata: Codable, Sendable {
        let issuer: String
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    internal func fetchAndValidate() async throws -> OAuthServerMetadata {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: URLRequest(url: OAuthConfiguration.metadataURL))
        } catch {
            throw Transport.translate(error)
        }

        try Transport.checkStatus(response)

        let metadata: OAuthServerMetadata
        do {
            metadata = try JSONDecoder().decode(OAuthServerMetadata.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }

        guard metadata.issuer == OAuthConfiguration.issuer.absoluteString else {
            throw ComfyError.authInvalid
        }

        guard metadata.authorizationEndpoint == OAuthConfiguration.authorizationEndpoint.absoluteString,
              metadata.tokenEndpoint == OAuthConfiguration.tokenEndpoint.absoluteString else {
            throw ComfyError.authInvalid
        }

        guard let methods = metadata.codeChallengeMethodsSupported,
              methods.contains(OAuthConfiguration.pkceCodeChallengeMethod) else {
            throw ComfyError.authInvalid
        }

        return metadata
    }
}
