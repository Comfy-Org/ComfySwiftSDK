//
//  ComfySDKInfo.swift
//  ComfySwiftSDK
//
//  Identifying metadata for the SDK, used for request traceability.
//

import Foundation

/// Lightweight identity for ComfySwiftSDK.
///
/// Every request the SDK makes carries `X-Comfy-Client: comfyswiftsdk/<version>`
/// so Comfy Cloud can attribute SDK traffic in its logs. This is deliberately
/// minimal — a single client header for traceability, not a telemetry channel.
/// No device, user, or usage data is attached; auth identity already rides the
/// bearer token's `client_id` claim.
enum ComfySDKInfo {
    /// SDK version. Keep in sync with the package's release tag.
    static let version = "0.1.0"

    /// Header name stamped on every SDK request.
    static let clientHeaderName = "X-Comfy-Client"

    /// Header value, e.g. `comfyswiftsdk/0.1.0`.
    static let clientHeaderValue = "comfyswiftsdk/\(version)"

    /// A `URLSessionConfiguration` (based on `.default`) that adds the client
    /// header to every task created from the session — including the WebSocket
    /// upgrade handshake. Per-request headers (auth, content-type) are set
    /// elsewhere and take precedence; this only adds the custom client header.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[clientHeaderName] = clientHeaderValue
        configuration.httpAdditionalHeaders = headers
        return configuration
    }
}
