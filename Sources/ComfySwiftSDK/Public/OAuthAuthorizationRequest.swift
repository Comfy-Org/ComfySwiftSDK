//
//  OAuthAuthorizationRequest.swift
//  ComfySwiftSDK
//
//  The SDK-built bundle the app needs to drive one PKCE
//  authorization-code attempt (Story 8.3, AC1/AC2). Produced by
//  `ComfyCloudClient.buildAuthorizationRequest()`; the app presents
//  `authorizationURL` in an `ASWebAuthenticationSession` (NFR-M2
//  carve-out — the web session lives in the app target, never here),
//  verifies the callback's `state` against `state`, and hands
//  `codeVerifier` back to `exchangeAuthorizationCode(_:codeVerifier:)`.
//
//  Privacy contract (NFR-S2): `codeVerifier` is a short-lived
//  credential and `state` is a CSRF nonce — neither may ever be
//  logged, persisted, or interpolated into any error message.
//
//  Story 8.3.
//

import Foundation

/// One PKCE authorization attempt's worth of material: the authorize
/// URL to present, the `state` nonce to verify on callback, and the
/// `code_verifier` to redeem at the token endpoint. Every attempt gets
/// a fresh instance — values are never reused across attempts
/// (RFC 7636 §4.1).
public struct OAuthAuthorizationRequest: Sendable {

    /// The fully-formed authorize URL to present in
    /// `ASWebAuthenticationSession`. Carries `response_type=code`, the
    /// client id, `state`, the S256 `code_challenge`, the RFC 8707
    /// `resource` parameter, and the registered `redirect_uri`.
    public let authorizationURL: URL

    /// The random CSRF nonce the app must verify against the callback's
    /// `state` query item; treat as a short-lived secret — never log
    /// (NFR-S2).
    public let state: String

    /// The PKCE verifier (RFC 7636, 43–128 chars). The app stores this
    /// for the duration of the attempt and hands it back to
    /// `ComfyCloudClient.exchangeAuthorizationCode(_:codeVerifier:)` —
    /// **never log** (NFR-S2).
    public let codeVerifier: String
}
