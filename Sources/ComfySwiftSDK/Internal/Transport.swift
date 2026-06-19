//
//  Transport.swift
//  ComfySwiftSDK
//
//  The only file in the SDK that constructs `URLRequest` instances and
//  calls `session.data(for:)`. Owns the two-mode credential injection
//  (`X-API-Key: <key>` in `.apiKey` mode, `Authorization: Bearer <token>`
//  in `.oauth` mode — see `applyAuth(to:)`), the JSON serialization of
//  the workflow body, the lightweight authenticated `validate`
//  round-trip, the best-effort cancel POST, and the canonical
//  status-code-to-`ComfyError` translation table.
//
//  This file (together with `WebSocketSession.swift`) is the only place
//  in the SDK that knows the Comfy Cloud HTTPS API URL — see
//  architecture.md §Integration Points line 658.
//
//  All errors thrown out of this actor are `ComfyError` cases — never
//  `URLError`, never `NSError`, never `DecodingError` raw. The
//  `translate(_:)` helper is the canonical mapper, shared with
//  `WebSocketSession`.
//
//  Logging in this file: credential-free error classification only via
//  `SDKLog` (see SDKLog.swift). `translate(_:)` logs the matched POSIX
//  code on socket-drop paths and the error type name on the `.unknown`
//  fallback. NEVER the API key, OAuth token, Authorization header value,
//  request body, response body, or any raw Error/URLRequest object.
//  Story 8.2 preserves this: neither the API key nor the OAuth access
//  token is ever logged or interpolated into an error. Story 8.5
//  preserves it again: the refresh token and the rotated token pair pass
//  through `performRefresh` and never touch any log.
//
//  Story 8.5 adds SDK-owned silent refresh for the `.oauthRefreshable`
//  credential mode: proactive pre-request refresh when the stored
//  expiry is within `proactiveRefreshMargin` (`refreshIfNearExpiry`),
//  a 401-intercept-refresh-retry-once wrapper around every retryable
//  method (`withAuthRetry`), and a coalescing `pendingRefreshTask` so
//  N concurrent 401s produce exactly one `grant_type=refresh_token`
//  POST (actor isolation is the serialization mechanism — single-use
//  refresh tokens make a concurrent double-refresh a family-revoke
//  lockout).
//
//  Story 1.5 (original), Story 8.2 (two-mode credential injection),
//  Story 8.5 (proactive + serialized refresh-on-401 for
//  `.oauthRefreshable`).
//

import Foundation

/// HTTP transport actor. Owns one `URLSession`, one base URL, and the
/// `ComfyCredential` whose value backs the per-request auth header.
/// Exposes `submitJob`, `validateAuth`, and best-effort `cancelJob`
/// methods. Every error thrown out of this actor is a `ComfyError`.
internal actor Transport {

    private let session: URLSession
    private let baseURL: URL
    private let credential: ComfyCredential

    // Coalescing refresh task (Story 8.5). Non-nil only while a refresh
    // POST is in flight. Actor isolation ensures exactly one task is
    // created per refresh window — all concurrent 401 interceptors await
    // the same Task.value (AC5 serialization contract).
    private var pendingRefreshTask: Task<OAuthTokenResponse, Error>?

    // Proactive refresh margin (Story 8.5): refresh the access token
    // when fewer than this many seconds remain before expiry. 60 seconds
    // covers clock skew, network round-trip latency, and processing time.
    private let proactiveRefreshMargin: TimeInterval = 60.0

    internal init(session: URLSession, baseURL: URL, credential: ComfyCredential) {
        self.session = session
        self.baseURL = baseURL
        self.credential = credential
    }

    // MARK: - Serialized silent refresh (Story 8.5)

    /// Coalescing refresh. Any caller that arrives while a refresh is
    /// already in flight awaits the same `Task` — no second refresh POST
    /// is issued. The `Task` is cleared from `pendingRefreshTask` when
    /// this method's activation returns (the `defer` runs after
    /// `await task.value` resumes on the actor), so the NEXT refresh —
    /// after the new token expires — creates a fresh `Task`.
    ///
    /// `tokenStore` is called INSIDE the task, before the task completes,
    /// guaranteeing persistence before any caller retries (AC6): a crash
    /// mid-rotation cannot orphan the token family, because no retried
    /// request ever runs ahead of the Keychain write.
    ///
    /// Why the `defer` is safe with actor re-entrancy: the clear is the
    /// last thing that happens before `performRefresh` returns its value
    /// to the caller, and both the `pendingRefreshTask` read and the
    /// clear are actor-isolated. A caller that lands between the task's
    /// completion and the clear awaits the already-completed task and
    /// gets the same rotated pair — never a second network call with
    /// the consumed refresh token.
    ///
    /// Failure path through the `defer` (review 8-5): if
    /// `refreshProvider`, the refresh POST, or `tokenStore` throws, the
    /// `defer` still clears `pendingRefreshTask`, so the next caller
    /// starts a fresh attempt. One sub-case is destructive: a
    /// `tokenStore` throw AFTER `executor.refresh()` succeeded discards
    /// a rotated pair whose single-use refresh token is already
    /// consumed at the AS — the Keychain still holds the stale refresh
    /// token, the next refresh POST replays it, and the family is
    /// revoked (re-sign-in required). The SDK deliberately attempts no
    /// recovery; `tokenStore` implementations must be robust. See the
    /// `OAuthTokenStore` typealias contract in `ComfyCredential.swift`.
    private func performRefresh(
        refreshProvider: @escaping OAuthRefreshProvider,
        tokenStore: @escaping OAuthTokenStore
    ) async throws -> OAuthTokenResponse {
        if let existing = pendingRefreshTask {
            return try await existing.value
        }
        let task = Task<OAuthTokenResponse, Error> {
            let executor = OAuthTokenRefreshExecutor(session: self.session)
            let refreshToken = try await refreshProvider()
            let newTokens = try await executor.refresh(using: refreshToken)
            try await tokenStore(newTokens)
            return newTokens
        }
        pendingRefreshTask = task
        defer { pendingRefreshTask = nil }
        return try await task.value
    }

    /// Proactive refresh check for the `.oauthRefreshable` case (AC3).
    /// Returns a fresh access token if the stored expiry is within the
    /// proactive margin (or `nil` expiry — treated as already expired).
    /// Returns `nil` when the token is comfortably in the future (no
    /// refresh needed; the caller falls through to a cheap
    /// `tokenProvider()` Keychain read).
    private func refreshIfNearExpiry(
        refreshProvider: @escaping OAuthRefreshProvider,
        tokenStore: @escaping OAuthTokenStore,
        expiryProvider: OAuthExpiryProvider
    ) async throws -> String? {
        let expiry = try expiryProvider()
        let needsRefresh = expiry.map { $0.timeIntervalSinceNow < proactiveRefreshMargin } ?? true
        guard needsRefresh else { return nil }
        let newTokens = try await performRefresh(
            refreshProvider: refreshProvider,
            tokenStore: tokenStore
        )
        return newTokens.accessToken
    }

    /// 401-intercept-refresh-retry-once wrapper (AC4). Calls `perform()`,
    /// intercepts `ComfyError.authInvalid` in `.oauthRefreshable` mode,
    /// refreshes once (coalesced via `performRefresh`), and retries the
    /// original operation exactly once. A second `.authInvalid` after the
    /// refresh — or a refresh failure — surfaces as `.authExpired`; there
    /// is no retry loop by construction. In `.apiKey` or
    /// `.oauth(tokenProvider:)` mode this is a pass-through, so API-key
    /// 401s keep surfacing as `.authInvalid` unchanged.
    private func withAuthRetry<T>(
        perform: () async throws -> T
    ) async throws -> T {
        guard case .oauthRefreshable(_, let refreshProvider, let tokenStore, _) = credential else {
            return try await perform()
        }
        do {
            return try await perform()
        } catch ComfyError.authInvalid {
            _ = try await performRefresh(refreshProvider: refreshProvider, tokenStore: tokenStore)
            // After the refresh, perform() re-runs applyAuth, whose
            // proactive check sees the new (far-future) expiry and falls
            // through to tokenProvider() — which reads the access token
            // tokenStore just wrote. The Keychain is the shared state;
            // no explicit token-passing is needed for the retry to use
            // the fresh credential.
            do {
                return try await perform()
            } catch ComfyError.authInvalid {
                throw ComfyError.authExpired
            }
        }
    }

    // MARK: - Auth header injection (Story 8.2)

    /// Inject the auth header for the active credential mode.
    /// `.apiKey` sets `X-API-Key: <key>` — synchronous, byte-identical
    /// to the Story 1.5 behavior; the method is `async` only for
    /// uniformity with the OAuth branches. `.oauth` calls the token
    /// provider and sets `Authorization: Bearer <token>`.
    /// `.oauthRefreshable` (Story 8.5) first runs the proactive
    /// near-expiry check — silently refreshing if needed — then sets
    /// the same Bearer header from the freshest token available.
    ///
    /// A token-provider failure that is not already a `ComfyError` is
    /// wrapped as `ComfyError.authInvalid` here, so every caller can
    /// propagate the error directly without extra mapping (AC3).
    /// Neither the key nor any token is ever logged (NFR-S2).
    ///
    /// Returns the resolved bearer token in the OAuth modes (`nil` in
    /// `.apiKey`) so `performSubmitPrompt` can mirror the exact token
    /// it just put on the wire into `extra_data.auth_token_comfy_org`
    /// for API-tier nodes (BE-1420). Most call sites only need the
    /// header side effect, hence `@discardableResult`.
    @discardableResult
    private func applyAuth(to request: inout URLRequest) async throws -> String? {
        switch credential {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
            return nil
        case .oauth(let tokenProvider):
            do {
                let token = try await tokenProvider()
                // An empty token would produce a syntactically invalid
                // `Authorization: Bearer ` header (RFC 6750) and surface
                // as an opaque server-side 401 — treat it as a provider
                // failure instead (review 8-2, MEDIUM).
                guard !token.isEmpty else { throw ComfyError.authInvalid }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return token
            } catch let e as ComfyError {
                throw e
            } catch {
                throw ComfyError.authInvalid  // non-ComfyError from provider → authInvalid
            }
        case .oauthRefreshable(let tokenProvider, let refreshProvider, let tokenStore, let expiryProvider):
            do {
                // Proactive refresh check first (AC3). If the token is
                // near-expiry or expired, perform a silent refresh and
                // use the new access token directly. Otherwise fall
                // through to tokenProvider() (cheap Keychain read).
                let freshToken = try await refreshIfNearExpiry(
                    refreshProvider: refreshProvider,
                    tokenStore: tokenStore,
                    expiryProvider: expiryProvider
                )
                // (`??` can't lazily await its right-hand side, so the
                // fallthrough is an explicit if/else.)
                let token: String
                if let freshToken {
                    token = freshToken
                } else {
                    token = try await tokenProvider()
                }
                guard !token.isEmpty else { throw ComfyError.authInvalid }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return token
            } catch let e as ComfyError {
                throw e
            } catch {
                throw ComfyError.authInvalid  // non-ComfyError from provider → authInvalid
            }
        }
    }

    // MARK: - Submit

    // MARK: - Upload Image

    /// Upload an image to Comfy Cloud via `POST /api/upload/image`.
    /// Returns the server-assigned filename (e.g. "input.jpg" or a
    /// UUID-based name). The workflow's `LoadImage` node must reference
    /// this filename. Story 3.4.
    internal func uploadImage(_ imageData: Data, mimeType: String) async throws -> String {
        try await withAuthRetry { try await performUploadImage(imageData, mimeType: mimeType) }
    }

    private func performUploadImage(_ imageData: Data, mimeType: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/upload/image")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        try await applyAuth(to: &urlRequest)

        let boundary = "ComfySwiftSDK-\(UUID().uuidString)"
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Determine file extension from MIME type
        let ext = mimeType == "image/png" ? "png" : "jpg"
        let filename = "input.\(ext)"

        // Build multipart body
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        urlRequest.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }

        // Story 4.1: refine 400/422 before generic checkStatus fallback.
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400 || http.statusCode == 422 {
            try Self.checkBody(data, status: http.statusCode)
        }

        try Self.checkStatus(response)

        // Parse response to get the uploaded filename
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String {
                return name
            }
            // Fallback: server may return just the filename string
            if let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            return filename
        } catch {
            return filename
        }
    }

    // MARK: - Submit

    /// Submit a workflow to Comfy Cloud and return the resulting
    /// `JobHandle`. Throws `ComfyError` on any failure.
    ///
    /// Story 3.4: if the request contains `.image` inputs, uploads them
    /// first via `POST /api/upload/image` and patches the workflow JSON's
    /// `LoadImage` nodes to reference the uploaded filename.
    ///
    /// The upload loop runs OUTSIDE the `withAuthRetry` scope that
    /// protects the `api/prompt` POST (review 8-5, MEDIUM): each upload
    /// is already individually protected by `uploadImage`'s own wrapper,
    /// so a 401 on the prompt POST retries only the POST — it never
    /// replays the loop and re-uploads every already-uploaded image.
    internal func submitJob(_ request: WorkflowRequest) async throws -> JobHandle {
        // Story 3.4: upload any image inputs before submitting.
        // Collect uploaded filenames to patch LoadImage nodes.
        var workflowJSON = request.workflowJSON
        for input in request.inputs {
            switch input {
            case .text, .seed:
                continue
            case .image(let imageData, let mimeType):
                let uploadedName = try await uploadImage(imageData, mimeType: mimeType)
                // Patch LoadImage nodes in the workflow to use the uploaded filename
                workflowJSON = Self.patchLoadImageNodes(workflowJSON, uploadedFilename: uploadedName)
            }
        }
        let patchedJSON = workflowJSON
        return try await withAuthRetry {
            try await performSubmitPrompt(workflowJSON: patchedJSON, extraData: request.extraData)
        }
    }

    private func performSubmitPrompt(
        workflowJSON: [String: Any],
        extraData: [String: Any]?
    ) async throws -> JobHandle {
        let url = baseURL.appendingPathComponent("api/prompt")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearerToken = try await applyAuth(to: &urlRequest)

        // Wrap the workflow JSON in the `{"prompt": ..., "extra_data": ...}`
        // envelope that Comfy Cloud expects. `extra_data` carries the
        // credential partner/API-tier nodes (Grok, Gemini, ByteDance,
        // etc.) read at execution time to call their backend services:
        // `api_key_comfy_org` in legacy mode (supplied by the app),
        // `auth_token_comfy_org` in OAuth mode — injected HERE from the
        // same post-refresh token applyAuth just put on the Authorization
        // header (BE-1420; mirrors the cloud web frontend / MCP server
        // contract). The Bearer header alone authenticates ingest routes
        // but NOT API-node upstream calls, so omitting this field fails
        // those nodes with a partner-side 401. The SDK owns token
        // plumbing (NFR-M2): a stale caller-supplied value is overwritten.
        var body: [String: Any] = ["prompt": workflowJSON]
        var mergedExtraData = extraData ?? [:]
        if let bearerToken {
            mergedExtraData["auth_token_comfy_org"] = bearerToken
        }
        if !mergedExtraData.isEmpty {
            body["extra_data"] = mergedExtraData
        }

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }

        // Story 4.1: refine 400/422 into serverRejected/contentFiltered
        // before the generic checkStatus fallback catches them as .network.
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400 || http.statusCode == 422 {
            try Self.checkBody(data, status: http.statusCode)
        }

        try Self.checkStatus(response)

        do {
            let dto = try JSONDecoder().decode(SubmitJobDTO.self, from: data)
            if let serverError = dto.error, !serverError.isEmpty {
                throw ComfyError.unknown(underlying: SubmitErrorBody(message: serverError))
            }
            return JobHandle(id: dto.promptId, reconnectToken: nil)
        } catch let comfyError as ComfyError {
            throw comfyError
        } catch {
            throw ComfyError.unknown(underlying: error)
        }
    }

    // MARK: - Validate

    /// Lightweight authenticated round-trip. Used by Story 1.6's
    /// `APIKeyEntryViewModel.connect()` flow. Hits `GET /api/queue` —
    /// the lightest authenticated endpoint exposed by Comfy Cloud per
    /// the Task 0 research note. Returns on any 2xx; throws
    /// `ComfyError.authInvalid` on 401/403; throws the same
    /// `.network`/`.offline`/`.timeout`/`.unknown` cases as
    /// `submitJob` for everything else.
    internal func validateAuth() async throws {
        try await withAuthRetry { try await performValidateAuth() }
    }

    private func performValidateAuth() async throws {
        let url = baseURL.appendingPathComponent("api/queue")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }

        try Self.checkStatus(response)
    }

    // MARK: - Job status polling (Story 4.4)

    /// Read the current status of a job via `GET /api/prompt/{prompt_id}`.
    /// Used by `PollingFallback` when the WebSocket transport is
    /// unavailable, and by `ReattachCoordinator` for a one-shot
    /// catch-up snapshot before resuming the event stream.
    ///
    /// Throws the same `ComfyError` cases as any other HTTP call;
    /// `.offline`/`.timeout` drive exponential backoff in the
    /// polling loop.
    internal func fetchJobStatus(id: String) async throws -> JobStatusDTO {
        try await withAuthRetry { try await performFetchJobStatus(id: id) }
    }

    private func performFetchJobStatus(id: String) async throws -> JobStatusDTO {
        let url = baseURL.appendingPathComponent("api/prompt/\(id)")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }

        try Self.checkStatus(response)

        do {
            return try JSONDecoder().decode(JobStatusDTO.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }
    }

    // MARK: - Cancel

    /// Best-effort job cancel. Fired from `WebSocketSession`'s stream
    /// `onTermination` closure when the consumer task is cancelled.
    /// Never throws — the user has already moved on, so any failure
    /// is silently swallowed. The Comfy Cloud API uses
    /// `POST /api/queue` with `{"delete": [prompt_id]}` per the
    /// Task 0 research note (there is no `DELETE /jobs/{id}` endpoint
    /// — the architecture document's wording was illustrative).
    ///
    /// Deliberately NOT wrapped in `withAuthRetry` (Story 8.5): this is
    /// best-effort fire-and-forget — a 401-refresh-retry cycle would add
    /// async overhead to an operation that swallows its result anyway.
    internal func cancelJob(id: String) async {
        let url = baseURL.appendingPathComponent("api/queue")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Best-effort auth (AC2 exception): this method never throws, so
        // a failing token provider is silently swallowed — the request
        // goes out without auth, the server rejects it, and the rejection
        // is swallowed by the existing `try?` below. The user has already
        // moved on. Routed through the shared `applyAuth(to:)` so the
        // credential→header mapping lives in exactly one place (review
        // 8-2, HIGH: the previous inline switch duplicated the mapping
        // and would silently diverge on any future credential change).
        _ = try? await applyAuth(to: &urlRequest)

        let body: [String: Any] = ["delete": [id]]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await session.data(for: urlRequest)
    }

    // MARK: - Output download

    /// Fetch a Comfy Cloud output file by its (`filename`, `subfolder`,
    /// `type`) coordinates. Used by `WebSocketSession`'s frame
    /// translator when an `executed` event names an output file.
    /// Returns the response bytes and the response's `Content-Type`
    /// (or `application/octet-stream` if the server omits it).
    internal func downloadView(
        filename: String,
        subfolder: String,
        type: String
    ) async throws -> (Data, String) {
        try await withAuthRetry {
            try await performDownloadView(filename: filename, subfolder: subfolder, type: type)
        }
    }

    private func performDownloadView(
        filename: String,
        subfolder: String,
        type: String
    ) async throws -> (Data, String) {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/view"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "subfolder", value: subfolder),
            URLQueryItem(name: "type", value: type)
        ]
        guard let url = components?.url else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }
        // Story 4.1: refine 400/422 before generic checkStatus fallback.
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400 || http.statusCode == 422 {
            try Self.checkBody(data, status: http.statusCode)
        }
        try Self.checkStatus(response)
        let mime = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, mime)
    }

    /// Stream a Comfy Cloud output to a temp file in the OS caches
    /// directory. Used for video outputs (and any other large media)
    /// per architecture.md §API & Communication line 180 ("Video in
    /// memory is a non-starter; stream→rename is safe and cheap").
    internal func downloadViewToTempFile(
        filename: String,
        subfolder: String,
        type: String,
        suggestedExtension: String
    ) async throws -> URL {
        try await withAuthRetry {
            try await performDownloadViewToTempFile(
                filename: filename,
                subfolder: subfolder,
                type: type,
                suggestedExtension: suggestedExtension
            )
        }
    }

    private func performDownloadViewToTempFile(
        filename: String,
        subfolder: String,
        type: String,
        suggestedExtension: String
    ) async throws -> URL {
        // Build the URL the same way as `downloadView`.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/view"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "subfolder", value: subfolder),
            URLQueryItem(name: "type", value: type)
        ]
        guard let url = components?.url else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await session.download(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }
        try Self.checkStatus(response)

        // Move the downloaded file to a stable temp path the caller
        // can hand off to `MediaStore`. The OS may evict files in the
        // caches directory under memory pressure, which is correct
        // for derived data per architecture.md §Data Architecture
        // line 154.
        let cachesDir: URL
        do {
            cachesDir = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw ComfyError.unknown(underlying: error)
        }
        let destination = cachesDir
            .appendingPathComponent("ComfySwiftSDK", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).\(suggestedExtension)")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }
        return destination
    }

    // MARK: - Workflow Patching

    /// Patch all `LoadImage` nodes in the workflow JSON to use the
    /// uploaded filename. Replaces the `image` input value (e.g.
    /// `"input.jpg"`) with the actual server-assigned filename.
    /// Story 3.4.
    static func patchLoadImageNodes(
        _ workflow: [String: Any],
        uploadedFilename: String
    ) -> [String: Any] {
        var patched = workflow
        for (nodeId, nodeValue) in workflow {
            guard var node = nodeValue as? [String: Any],
                  let classType = node["class_type"] as? String,
                  classType == "LoadImage",
                  var inputs = node["inputs"] as? [String: Any] else {
                continue
            }
            inputs["image"] = uploadedFilename
            node["inputs"] = inputs
            patched[nodeId] = node
        }
        return patched
    }

    // MARK: - Status code translation

    /// Translate any `Error` thrown during transport into a
    /// `ComfyError`. Shared with `WebSocketSession` so the two transport
    /// actors map errors identically.
    static func translate(_ error: Error) -> ComfyError {
        if let comfyError = error as? ComfyError {
            return comfyError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .dataNotAllowed:
                return .offline
            case .timedOut:
                return .timeout
            default:
                return .network(underlying: urlError)
            }
        }
        // Map POSIX socket-drop codes to `.network` (transient) so the
        // polling fallback retries on resume instead of surfacing a false
        // failure. These codes are delivered as `NSError` in the POSIX
        // domain when the OS kills the underlying socket — most commonly
        // when the app is backgrounded mid-job and the connection is torn
        // down (ENOTCONN, ECONNRESET, ECONNABORTED), or when the network
        // interface disappears (ENETDOWN, ENETUNREACH, EHOSTUNREACH), or
        // the request times out at the socket level (ETIMEDOUT, EPIPE).
        // None of these indicate a job-level failure; they indicate that
        // the *transport* blipped and the job should be re-polled.
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain,
           [ENOTCONN, ECONNRESET, ECONNABORTED, ENETDOWN, ENETUNREACH, ETIMEDOUT, EPIPE, EHOSTUNREACH]
               .contains(Int32(ns.code)) {
            // Log the matched POSIX code — classification only, no URL/body/credential.
            SDKLog.transportPOSIXTranslated(code: Int32(ns.code))
            return .network(underlying: error)
        }
        // Log the unknown fallback — type name only, never the error's localizedDescription
        // or any associated value that might carry header/credential material.
        SDKLog.transportUnknownFallback(errorType: String(describing: type(of: error)))
        return .unknown(underlying: error)
    }

    /// Inspect an `HTTPURLResponse` and throw a `ComfyError` for any
    /// non-2xx status. Resolves codes that need only headers (no body):
    /// 401/403 → `.authInvalid`, 429 → `.rateLimited`, 451 → `.contentFiltered`.
    /// Other 4xx/5xx → `.network(underlying:)` fallback.
    ///
    /// Call sites that have the response `Data` should also call
    /// `checkBody(_:status:)` after this method for 400/422 refinement.
    ///
    /// Story 1.5 (original), Story 4.1 (429/451 expansion).
    static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ComfyError.unknown(underlying: URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw ComfyError.authInvalid
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
                .flatMap { $0 > 0 ? $0 : nil }
            throw ComfyError.rateLimited(retryAfter: retryAfter)
        case 451:
            throw ComfyError.contentFiltered
        default:
            throw ComfyError.network(underlying: URLError(.badServerResponse))
        }
    }

    /// Inspect a response body for structured rejection reasons on
    /// 400/422 responses. Call sites invoke this **before** `checkStatus`
    /// when the status is 400/422 and they have the response `Data`.
    /// If the body contains a recognisable reason, this method throws
    /// a refined `ComfyError`. If the body is unparseable or
    /// unrecognisable, it **returns without throwing** so the caller
    /// can fall through to `checkStatus`'s generic `.network` fallback.
    ///
    /// Story 4.1.
    static func checkBody(_ data: Data, status: Int) throws {
        guard status == 400 || status == 422 else { return }

        // Support both flat and nested JSON error shapes:
        //   {"error": "message"}
        //   {"error": {"message": "..."}}
        //   {"reason": "message"}
        //   {"message": "message"}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return // Unparseable body — let checkStatus handle it
        }

        let message: String
        if let flat = json["error"] as? String {
            message = flat
        } else if let nested = json["error"] as? [String: Any],
                  let inner = nested["message"] as? String {
            message = inner
        } else {
            message = (json["reason"] as? String)
                ?? (json["message"] as? String)
                ?? ""
        }

        // No usable message — fall through to checkStatus
        guard !message.isEmpty else { return }

        let lower = message.lowercased()

        // Content filter indicators in the body
        if lower.contains("content filter") || lower.contains("nsfw") || lower.contains("safety") {
            throw ComfyError.contentFiltered
        }

        // Model unavailable
        if lower.contains("model") && (lower.contains("unavailable") || lower.contains("not found") || lower.contains("not available")) {
            throw ComfyError.serverRejected(reason: .modelUnavailable)
        }

        // Quota exceeded
        if lower.contains("quota") || lower.contains("limit exceeded") || lower.contains("billing") {
            throw ComfyError.serverRejected(reason: .quotaExceeded)
        }

        // Malformed workflow — note parens: both conditions must match
        if lower.contains("workflow") || (lower.contains("prompt") && lower.contains("invalid")) {
            throw ComfyError.serverRejected(reason: .malformedWorkflow)
        }

        throw ComfyError.serverRejected(reason: .other(message))
    }
}

/// Internal sentinel `Error` used so the SDK can route a server-side
/// `error` field on the submit response through `ComfyError.unknown`
/// without leaking the original string at the type level. The
/// presentation layer (Epic 4) will eventually inspect this via
/// `as?` and surface the message — but Story 1.5 routes it through
/// `.unknown` because the full taxonomy is not yet wired.
struct SubmitErrorBody: Error {
    let message: String
}
