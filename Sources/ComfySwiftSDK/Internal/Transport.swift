import Foundation

internal actor Transport {

    private let session: URLSession
    private let baseURL: URL
    private let credential: ComfyCredential

    private var pendingRefreshTask: Task<OAuthTokenResponse, Error>?

    private let proactiveRefreshMargin: TimeInterval = 60.0

    internal init(session: URLSession, baseURL: URL, credential: ComfyCredential) {
        self.session = session
        self.baseURL = baseURL
        self.credential = credential
    }

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
            do {
                return try await perform()
            } catch ComfyError.authInvalid {
                throw ComfyError.authExpired
            }
        }
    }

    @discardableResult
    private func applyAuth(to request: inout URLRequest) async throws -> String? {
        switch credential {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
            return nil
        case .oauth(let tokenProvider):
            do {
                let token = try await tokenProvider()
                guard !token.isEmpty else { throw ComfyError.authInvalid }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return token
            } catch let e as ComfyError {
                throw e
            } catch {
                throw ComfyError.authInvalid
            }
        case .oauthRefreshable(let tokenProvider, let refreshProvider, let tokenStore, let expiryProvider):
            do {
                let freshToken = try await refreshIfNearExpiry(
                    refreshProvider: refreshProvider,
                    tokenStore: tokenStore,
                    expiryProvider: expiryProvider
                )
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
                throw ComfyError.authInvalid
            }
        }
    }

    /// Shared HTTP plumbing for the `session.data(for:)`-based endpoints. Sends the
    /// request (auth is applied per-caller beforehand), translates transport errors,
    /// runs the 400/422 error-body check, then the status check. Decoding stays
    /// per-caller. The `download(for:)`-based temp-file path and the deliberately
    /// swallowing `cancelJob` do not route through here.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.translate(error)
        }

        if let http = response as? HTTPURLResponse,
           http.statusCode == 400 || http.statusCode == 422 {
            try Self.checkBody(data, status: http.statusCode)
        }

        try Self.checkStatus(response)
        return (data, response)
    }

    /// Builds the `api/view` URL shared by the two download endpoints, failing fast
    /// on a malformed URL rather than composing a request against a bad base.
    private func viewURL(filename: String, subfolder: String, type: String) throws -> URL {
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
        return url
    }

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

        let ext = mimeType == "image/png" ? "png" : "jpg"
        let filename = "input.\(ext)"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        urlRequest.httpBody = body

        let (data, _) = try await send(urlRequest)

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String {
                return name
            }
            if let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            return filename
        } catch {
            return filename
        }
    }

    internal func submitJob(_ request: WorkflowRequest) async throws -> JobHandle {
        // Interim guard (issue #16): patchLoadImageNodes rewrites *every* LoadImage node, so a
        // second image input would silently overwrite the first ("last image wins"). Until keyed
        // input→node mapping lands, fail fast rather than bind the wrong image to a node.
        let imageInputCount = request.inputs.reduce(into: 0) { count, input in
            if case .image = input { count += 1 }
        }
        guard imageInputCount <= 1 else {
            throw ComfyError.serverRejected(reason: .other("multiple_image_inputs_unsupported"))
        }
        var workflowJSON = request.workflowJSON
        for input in request.inputs {
            switch input {
            case .text, .seed:
                continue
            case .image(let imageData, let mimeType):
                let uploadedName = try await uploadImage(imageData, mimeType: mimeType)
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

        let (data, _) = try await send(urlRequest)

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

    internal func validateAuth() async throws {
        try await withAuthRetry { try await performValidateAuth() }
    }

    private func performValidateAuth() async throws {
        let url = baseURL.appendingPathComponent("api/queue")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        _ = try await send(urlRequest)
    }

    internal func fetchJobStatus(id: String) async throws -> JobDetailResponse {
        try await withAuthRetry { try await performFetchJobStatus(id: id) }
    }

    private func performFetchJobStatus(id: String) async throws -> JobDetailResponse {
        let url = baseURL.appendingPathComponent("api/jobs/\(id)")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        let (data, _) = try await send(urlRequest)

        do {
            return try JSONDecoder().decode(JobDetailResponse.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }
    }

    internal func cancelJob(id: String) async {
        let url = baseURL.appendingPathComponent("api/jobs/\(id)/cancel")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        _ = try? await applyAuth(to: &urlRequest)
        _ = try? await session.data(for: urlRequest)
    }

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
        let url = try viewURL(filename: filename, subfolder: subfolder, type: type)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        try await applyAuth(to: &urlRequest)

        let (data, response) = try await send(urlRequest)
        let mime = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, mime)
    }

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
        let url = try viewURL(filename: filename, subfolder: subfolder, type: type)
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
        // `download(for:)` streams the body to a temp file rather than into memory, so
        // it can't share `send`. Mirror its 400/422 error-body check by reading the
        // (small) error payload back off disk, keeping this endpoint consistent with
        // `performDownloadView` — a rejected video download surfaces `.serverRejected`
        // rather than a generic `.network` error.
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400 || http.statusCode == 422 {
            let body = (try? Data(contentsOf: downloadedURL)) ?? Data()
            try Self.checkBody(body, status: http.statusCode)
        }
        try Self.checkStatus(response)

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
        let safeExtension = Self.sanitizedExtension(suggestedExtension)
        let destination = cachesDir
            .appendingPathComponent("ComfySwiftSDK", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).\(safeExtension)")
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

    /// Normalizes a server-supplied file extension before it is interpolated into an on-disk
    /// cache path. The value is derived from the server's response (content type / filename), so
    /// a `/`, `\`, or `..` in it could shape the path outside the intended `UUID().<ext>` filename.
    /// Anything not matching `[a-z0-9]{1,10}` (slashes, dots, traversal, empty, overlong) collapses
    /// to `bin`, so a hostile or garbled extension can never escape the filename shape.
    static func sanitizedExtension(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let isSafe = lowered.range(of: #"^[a-z0-9]{1,10}$"#, options: .regularExpression) != nil
        return isSafe ? lowered : "bin"
    }

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
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain,
           [ENOTCONN, ECONNRESET, ECONNABORTED, ENETDOWN, ENETUNREACH, ETIMEDOUT, EPIPE, EHOSTUNREACH]
               .contains(Int32(ns.code)) {
            SDKLog.transportPOSIXTranslated(code: Int32(ns.code))
            return .network(underlying: error)
        }
        SDKLog.transportUnknownFallback(errorType: String(describing: type(of: error)))
        return .unknown(underlying: error)
    }

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

    static func checkBody(_ data: Data, status: Int) throws {
        guard status == 400 || status == 422 else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
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

        guard !message.isEmpty else { return }

        let lower = message.lowercased()

        if lower.contains("content filter") || lower.contains("nsfw") || lower.contains("safety") {
            throw ComfyError.contentFiltered
        }

        if lower.contains("model") && (lower.contains("unavailable") || lower.contains("not found") || lower.contains("not available")) {
            throw ComfyError.serverRejected(reason: .modelUnavailable)
        }

        if lower.contains("quota") || lower.contains("limit exceeded") || lower.contains("billing") {
            throw ComfyError.serverRejected(reason: .quotaExceeded)
        }

        if lower.contains("workflow") || (lower.contains("prompt") && lower.contains("invalid")) {
            throw ComfyError.serverRejected(reason: .malformedWorkflow)
        }

        throw ComfyError.serverRejected(reason: .other(message))
    }
}

struct SubmitErrorBody: Error {
    let message: String
}
