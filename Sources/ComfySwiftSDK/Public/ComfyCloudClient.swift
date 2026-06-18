//
//  ComfyCloudClient.swift
//  ComfySwiftSDK
//
//  The SDK's only public façade. Every consumer constructs one of these
//  with `init(credential:)` (or the legacy `init(apiKey:)`, which
//  delegates to it) and calls one of its four methods. There are no
//  delegates, callbacks, or Combine publishers anywhere in the SDK
//  contract surface (NFR-M4).
//
//  `final` class — no subclassing. Extensibility lives in
//  `WorkflowRequest.workflowJSON` (the app's `ModelCatalog.workflowBuilder`
//  produces per-model graphs that the SDK posts opaquely).
//
//  Privacy contract (NFR-S2 / NFR-S3): credentials — the legacy API key
//  and, in OAuth mode, every access token returned by the token
//  provider — are held privately and never logged, never returned,
//  never exposed in any public property, and never interpolated into
//  any error message, regardless of mode. The SDK does no logging at
//  all (see Story 1.5 Dev Notes "SDK observability is deferred"); the
//  privacy contract is enforced by
//  `ComfyMobileTests/Enforcement/NoAPIKeyInLogsTests` exercising
//  `client.validate()` under a captured-log sink.
//
//  This file is a thin façade. The four methods delegate one-to-one
//  into `Transport` and `WebSocketSession`. There is no business logic
//  in this file beyond the credential plumbing.
//
//  baseURL is the single source of truth for the Comfy Cloud HTTPS
//  API base URL across the SDK (architecture.md §Integration Points
//  line 658 — only `Transport.swift` and `WebSocketSession.swift` know
//  the URL, and both receive it from this constructor). Storing the
//  literal here means there is exactly one place to change if the URL
//  ever moves. The Story 1.5 Task 0 research note documents how the
//  value was discovered and links to the Comfy.org API reference.
//
//  OAuth entry points (Story 8.3): two `static` methods bracket the
//  app-driven browser handshake (NFR-M2 carve-out — the
//  ASWebAuthenticationSession itself lives in the app target, never
//  here). `buildAuthorizationRequest()` mints a fresh PKCE
//  verifier/challenge + `state` nonce and the fully-formed authorize
//  URL; `exchangeAuthorizationCode(_:codeVerifier:)` redeems the
//  callback's code at `/oauth/token` and returns the token pair for
//  the app to store (Story 8.4). Both are `static` deliberately — no
//  client credential exists yet at sign-in time.
//
//  CryptoKit is imported solely for `SHA256` (the PKCE S256 challenge).
//  It is an Apple system framework outside the SDK boundary denylist
//  (`SwiftUI`/`SwiftData`/`Photos`/`Security`) and is allowlisted in
//  `SDKImportBoundaryTests` per the Story 8.3 review.
//
//  Story 1.5 (original), Story 8.2 (two-mode credential source),
//  Story 8.3 (PKCE authorization-code flow entry points).
//

import Foundation
import CryptoKit

/// The SDK's public façade. Construct one of these with an API key
/// and call `submit(_:)`, `events(for:)`, or `validate()`. Cancellation
/// is cooperative via `Task.cancel()` on the consumer task — there is
/// no explicit `cancel(handle:)` method (architecture.md §Process
/// Patterns line 346).
public final class ComfyCloudClient: Sendable {

    /// The Comfy Cloud HTTPS API base URL. Source: Comfy.org official
    /// API reference (https://docs.comfy.org/development/cloud/api-reference)
    /// per the Story 1.5 Task 0 research note. Compile-time constant;
    /// the force-unwrap is sanctioned because the URL is a literal
    /// (Swift has no `URL(staticString:)` convenience in the iOS 17
    /// minimum target).
    private static let baseURL: URL = URL(string: "https://cloud.comfy.org")!

    private let transport: Transport
    private let webSocketSession: WebSocketSession
    private let reattachCoordinator: ReattachCoordinator

    /// Construct a client bound to one credential mode (Story 8.2).
    /// `.apiKey` injects `X-API-Key` exactly as the legacy constructor;
    /// `.oauth` calls the token provider per request and injects
    /// `Authorization: Bearer <token>`. The credential is held privately
    /// and never logged, returned, or exposed in any form.
    public init(credential: ComfyCredential) {
        let session = URLSession(configuration: ComfySDKInfo.sessionConfiguration())
        let transport = Transport(
            session: session,
            baseURL: Self.baseURL,
            credential: credential
        )
        self.transport = transport
        self.webSocketSession = WebSocketSession(
            session: session,
            baseURL: Self.baseURL,
            credential: credential,
            transport: transport
        )
        self.reattachCoordinator = ReattachCoordinator(transport: transport)
    }

    /// Construct a client bound to one API key. The key is held
    /// privately and never logged, returned, or exposed. Delegates to
    /// `init(credential:)` with `.apiKey` — behavior is identical to
    /// the pre-Story-8.2 constructor (coexistence, no breaking change).
    /// (`convenience` because a class initializer may only delegate
    /// with `self.init` from a convenience initializer.)
    public convenience init(apiKey: String) {
        self.init(credential: .apiKey(apiKey))
    }

    /// Submit a workflow to Comfy Cloud and return a handle for
    /// streaming its lifecycle events. Throws `ComfyError` on any
    /// failure (auth, network, malformed body, server rejection).
    public func submit(_ request: WorkflowRequest) async throws -> JobHandle {
        try await transport.submitJob(request)
    }

    /// Open a cold stream of lifecycle events for a previously
    /// submitted job. The WebSocket connection opens when the consumer
    /// first iterates the returned stream. Cancellation via
    /// `Task.cancel()` on the consumer fires a best-effort server-side
    /// cancel and yields exactly one `.cancelled` event before the
    /// stream finishes.
    ///
    /// **Failure type:** the stream is typed as
    /// `AsyncThrowingStream<JobEvent, Error>` (not `<JobEvent, ComfyError>`)
    /// solely because typed-throws on `AsyncThrowingStream` requires
    /// Swift 6 / iOS 18, and this package targets iOS 17. The runtime
    /// contract still holds — every error thrown from this stream is a
    /// `ComfyError`, and consumers MAY use `as? ComfyError` (or a
    /// `do/catch let e as ComfyError` pattern) without a fallback
    /// branch. The `Transport.translate(_:)` helper is the canonical
    /// mapper and is exhaustively tested. When the package's minimum
    /// is bumped to iOS 18, this signature should be tightened to
    /// `AsyncThrowingStream<JobEvent, ComfyError>` so the type system
    /// — not a doc comment — enforces the taxonomy at the boundary
    /// (cursor-reviews fix #7 — deferred until iOS 18 minimum).
    public func events(for handle: JobHandle) -> AsyncThrowingStream<JobEvent, Error> {
        webSocketSession.eventStream(for: handle)
    }

    /// Resume an existing job's event stream after a network drop
    /// (Story 4.4, AC3 / FR22 / NFR-R2). The SDK issues a single
    /// HTTP GET to catch up on the job's current state, synthesizes
    /// a catch-up `.queued` (and `.progress`, if running) so the
    /// consumer's FR21 state machine jumps to the right phase, then
    /// continues yielding events via polling until terminal.
    ///
    /// If the job has already terminated by the time this method is
    /// called, the returned stream emits exactly one terminal event
    /// (`.complete` / `.failed` / `.cancelled`) and closes.
    ///
    /// Same failure-type caveat as `events(for:)`: the stream is
    /// typed `<JobEvent, Error>` because typed-throws on
    /// `AsyncThrowingStream` requires iOS 18; every error thrown here
    /// is still a `ComfyError` at runtime.
    public func reattach(
        to handle: JobHandle,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        reattachCoordinator.reattach(to: handle, hasEmittedFinalizing: hasEmittedFinalizing)
    }

    /// Reattach to an in-flight job by its opaque `promptId` — used by
    /// the app's cold-launch adoption path to resume after process
    /// termination (Story 4.9, FR38 extension). Constructs a `JobHandle`
    /// internally and delegates to `reattach(to:hasEmittedFinalizing:)`,
    /// so the transport-level behavior is identical to an in-session
    /// reattach after a network drop.
    ///
    /// The `promptId` is the opaque string returned by a prior
    /// `submit(_:)` call and exposed via `JobHandle.id`. This overload
    /// exists so callers that persisted the id across a process death can
    /// resume without having to reconstruct a handle themselves —
    /// `JobHandle.init` is deliberately `internal` so handles only ever
    /// originate from `submit(_:)` or this method.
    public func reattach(
        promptId: String,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        let handle = JobHandle(id: promptId, reconnectToken: nil)
        return reattachCoordinator.reattach(
            to: handle,
            hasEmittedFinalizing: hasEmittedFinalizing
        )
    }

    /// Lightweight authenticated round-trip. Used by Story 1.6's
    /// `APIKeyEntryViewModel.connect()` flow to validate a freshly
    /// pasted API key without committing it to the Keychain.
    /// Returns on success; throws `ComfyError.authInvalid` on
    /// 401/403; throws the same `.network`/`.offline`/`.timeout`/
    /// `.unknown` cases as `submit(_:)` for everything else.
    ///
    /// In OAuth mode, the token provider is called first; a failing
    /// provider throws `.authInvalid`. Then the same GET /api/queue
    /// round-trip runs with the Bearer token (Story 8.2, AC3).
    public func validate() async throws {
        try await transport.validateAuth()
    }

    /// Detach the live WebSocket event stream for `jobId` WITHOUT
    /// triggering the FR23 server-side cancel POST.
    ///
    /// Use this when the app needs to stop consuming events from the
    /// existing WebSocket — typically because it is about to open a
    /// reattach polling stream — but the cloud-side job MUST keep
    /// running. Cancelling the consumer task instead would terminate
    /// the stream with `.cancelled`, which fires the cooperative
    /// cancel POST that aborts the user's job.
    ///
    /// The stream's consumer sees its `for try await` loop end
    /// normally (no thrown error). `submit(_:)` / `events(for:)`
    /// remain available to start a fresh stream for the same job.
    ///
    /// No-op if no stream is currently registered for `jobId`.
    public func detachEvents(jobId: String) {
        webSocketSession.detachStream(jobId: jobId)
    }

    // MARK: - OAuth sign-in entry points (Story 8.3)

    /// The custom URL scheme the app passes to
    /// `ASWebAuthenticationSession(callbackURLScheme:)`. Re-exported
    /// from the internal `OAuthConfiguration` so the scheme keeps a
    /// single source of truth inside the SDK while remaining reachable
    /// from the app target (Story 8.3 Dev Notes Option A).
    public static let oauthCallbackScheme: String = OAuthConfiguration.callbackScheme

    /// Mint the material for one PKCE authorization attempt (AC1):
    /// a fresh RFC 7636 `code_verifier` (32 random bytes, base64url,
    /// 43 chars), its S256 `code_challenge`, a fresh `state` CSRF
    /// nonce (16 random bytes, base64url, 22 chars), and the
    /// fully-formed authorize URL on
    /// `OAuthConfiguration.authorizationEndpoint`.
    ///
    /// `static` deliberately — no client credential exists yet at
    /// sign-in time. Randomness comes from
    /// `SystemRandomNumberGenerator` (arc4random_buf on Apple
    /// platforms — cryptographically secure, no `Security` import).
    ///
    /// NFR-S2: the returned `codeVerifier` and `state` are secrets;
    /// nothing in this method logs, and callers must not either.
    public static func buildAuthorizationRequest() -> OAuthAuthorizationRequest {
        var rng = SystemRandomNumberGenerator()

        // code_verifier (RFC 7636 §4.1): 32 random bytes, base64url
        // without padding — exactly 43 URL-safe chars (spec: 43–128).
        let rawBytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let codeVerifier = base64URLEncode(Data(rawBytes))

        // code_challenge (RFC 7636 §4.2): BASE64URL(SHA256(verifier)).
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = base64URLEncode(Data(digest))

        // state: 16 random bytes → 22 base64url chars — sufficient
        // entropy for a CSRF nonce.
        let stateBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let state = base64URLEncode(Data(stateBytes))

        // Both guards below signal programmer error (a malformed
        // compile-time constant in `OAuthConfiguration`), not a runtime
        // condition — the signature stays non-throwing per the Story
        // 8.3 contract, and a loud crash in development is the intended
        // failure mode (Story 8.3 review, F1/F2/NJ1).
        guard var components = URLComponents(
            url: OAuthConfiguration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            fatalError("OAuthConfiguration.authorizationEndpoint is not a parseable URL")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: OAuthConfiguration.clientId),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: OAuthConfiguration.pkceCodeChallengeMethod),
            URLQueryItem(name: "scope", value: OAuthConfiguration.scope),
            URLQueryItem(name: "resource", value: OAuthConfiguration.resourceParameter),
            URLQueryItem(name: "redirect_uri", value: OAuthConfiguration.redirectURI),
        ]
        guard let url = components.url else {
            fatalError("OAuthConfiguration produced an invalid authorize URL")
        }

        return OAuthAuthorizationRequest(
            authorizationURL: url,
            state: state,
            codeVerifier: codeVerifier
        )
    }

    /// Redeem the authorization code captured from the web-session
    /// callback for a token pair (AC2). The exchange POSTs to
    /// `/oauth/token` with the `code_verifier` and no client secret
    /// (`token_endpoint_auth_method=none`). Throws `ComfyError` on any
    /// failure; returns the token pair for Keychain storage (Story 8.4).
    ///
    /// `static` deliberately — the OAuth `ComfyCloudClient` instance is
    /// only constructed *after* tokens exist (Story 8.6).
    ///
    /// NFR-S2: `code`, `codeVerifier`, and both returned token
    /// fragments are secrets; nothing in this path logs.
    public static func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> OAuthTokenResponse {
        let exchanger = OAuthExchanger(session: URLSession(configuration: ComfySDKInfo.sessionConfiguration()))
        return try await exchanger.exchange(code: code, codeVerifier: codeVerifier)
    }

    /// Base64url without padding (RFC 4648 §5) — the encoding RFC 7636
    /// mandates for both the verifier and the challenge.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
