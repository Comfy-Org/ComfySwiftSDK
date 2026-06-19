//
//  WebSocketSession.swift
//  ComfySwiftSDK
//
//  The only file in the SDK that opens a `URLSessionWebSocketTask`.
//  Owns the WebSocket read loop, the frame-to-`JobEvent` translation,
//  the media download for `executed`-then-`execution_success` paths,
//  and the FR23 cooperative-cancel path that fires the best-effort
//  `POST /api/queue {"delete":[id]}` and yields `.cancelled` exactly
//  once.
//
//  This file (together with `Transport.swift`) is the only place in
//  the SDK that knows the Comfy Cloud HTTPS API URL — see
//  architecture.md §Integration Points line 658.
//
//  Cold stream semantics (architecture.md §API & Communication line 174):
//    `eventStream(for:)` returns synchronously. The work happens inside
//    the `AsyncThrowingStream { continuation in ... }` closure body,
//    which is invoked when the consumer first iterates. Calling
//    `events(for:)` twice on the same handle opens two separate
//    WebSocket connections; this is intentional. Story 4.4's
//    `reattach(to:)` is the only sanctioned way to resume an existing
//    job's event stream after a network drop.
//
//  Fraction clamping (AC3): `progress.fraction` is clamped to
//  `[0.0, 1.0]` before yielding. Defense in depth — a malformed
//  server frame must not propagate `1.5` or `-0.2` into the UI ticker.
//
//  Comfy Cloud frame mapping (Story 1.5 Task 0 research):
//    - `executing` (with `node` set) → `.progress(fraction: <last>, phase: <node-derived>)`
//    - `executing` (with `node == nil`) → `.finalizing` (workflow finished, outputs pending)
//    - `progress` (`value`/`max`)    → `.progress(fraction: clamped(value/max), phase: <last node>)`
//    - `executed`                    → buffer the per-node output payload
//    - `execution_success`           → fetch every buffered output via Transport.downloadView,
//                                      build a WorkflowOutput, yield `.complete(output)`
//    - `execution_error`             → decode `ExecutionErrorFrameData` so the
//                                      server-provided `exception_type` /
//                                      `exception_message` survive into a typed
//                                      `JobExecutionError` sentinel wrapped in
//                                      `ComfyError.unknown(underlying:)`. Story 4.1
//                                      will reclassify the well-known cases into
//                                      `.jobFailed(phase:)` / `.contentFiltered` /
//                                      etc., but the diagnostics must round-trip
//                                      to the consumer (cursor-reviews fix #2 —
//                                      previously this branch synthesized a
//                                      generic `URLError(.badServerResponse)` and
//                                      destroyed every byte of server context).
//    - `execution_interrupted`       → yield `.cancelled` (server-initiated cancel)
//    - first frame received          → first emit `.queued` once (synthesized — Comfy Cloud
//                                      has no `queued` discriminator distinct from the absence
//                                      of `executing`; the SDK synthesizes one `.queued` event
//                                      at stream start so the FR21 state machine has a uniform
//                                      `queued → progress → ...` sequence)
//
//  Logging in this file: credential-free error classification only via
//  `SDKLog` (see SDKLog.swift). Logged: ComfyError case name + jobId
//  at output-build failures, execution_error frames, and the read-loop
//  transient→polling handoff decision. NEVER the token, URL, frame
//  body, output bytes, or any raw Error / URLResponse object.
//
//  WebSocket auth: in `.apiKey` mode the key travels in the URL as a
//  `token` query parameter (`wss://cloud.comfy.org/ws?clientId=...&token=<key>`)
//  — byte-identical to Story 1.5. Comfy Cloud's WebSocket endpoint does
//  not support custom headers. The whole URL is therefore sensitive and
//  MUST never be logged. In `.oauth` / `.oauthRefreshable` modes the
//  Bearer JWT rides the same `?token=` parameter, fetched from the
//  token provider at connection time — Bearer JWT injection
//  implemented in Story 8.5 (see `buildWebSocketURL(baseURL:credential:clientID:)`).
//
//  Story 1.5 (original), Story 8.2 (two-mode credential),
//  Story 8.5 (OAuth ?token= injection).
//

import Foundation

/// Lock-protected map of in-flight stream continuations keyed by jobId.
/// Lives outside the `WebSocketSession` actor so the nonisolated
/// `eventStream(for:)` closure body can register / unregister entries
/// synchronously without an `await`. Used by `detachStream(jobId:)` to
/// finish a live stream's continuation cleanly (`.finished` reason) so
/// `onTermination` skips the FR23 server-cancel POST.
internal final class WebSocketStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: AsyncThrowingStream<JobEvent, Error>.Continuation] = [:]

    func register(_ continuation: AsyncThrowingStream<JobEvent, Error>.Continuation, for jobId: String) {
        lock.lock(); defer { lock.unlock() }
        continuations[jobId] = continuation
    }

    func unregister(jobId: String) {
        lock.lock(); defer { lock.unlock() }
        continuations.removeValue(forKey: jobId)
    }

    func detach(jobId: String) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: jobId)
        lock.unlock()
        continuation?.finish()
    }
}

/// WebSocket transport actor. Owns the per-stream state and the frame
/// translator. Returns a cold `AsyncThrowingStream<JobEvent, Error>`
/// that connects on first iteration.
internal actor WebSocketSession {

    private let session: URLSession
    private let baseURL: URL
    private let credential: ComfyCredential
    private let transport: Transport
    /// A3 fix: clock injected so the WS→polling handoff path can be
    /// time-controlled in tests. Production uses `ContinuousClock()`.
    private let clock: any Clock<Duration>
    /// Registry of live stream continuations, keyed by jobId. Used by
    /// `detachStream(jobId:)` to finish a stream gracefully without
    /// triggering FR23 server-cancel — see Story 4.7 follow-up that
    /// fixes the stall-reattach path inadvertently killing user jobs.
    private nonisolated let streamRegistry = WebSocketStreamRegistry()

    internal init(
        session: URLSession,
        baseURL: URL,
        credential: ComfyCredential,
        transport: Transport,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.session = session
        self.baseURL = baseURL
        self.credential = credential
        self.transport = transport
        self.clock = clock
    }

    /// Finish the live event stream for `jobId` with a `.finished`
    /// termination reason instead of `.cancelled`, so the stream's
    /// `onTermination` closure SKIPS the FR23 server-cancel POST.
    ///
    /// Use this from the app side when you want to stop consuming
    /// events without telling the cloud to abort the job — e.g.
    /// Story 4.7's stall-reattach handoff, where the local socket
    /// is being swapped for a polling stream but the job itself
    /// must keep running on the server.
    ///
    /// No-op if no stream is currently registered for `jobId`.
    nonisolated internal func detachStream(jobId: String) {
        streamRegistry.detach(jobId: jobId)
    }

    /// Cold stream of lifecycle events for one in-flight job. The
    /// WebSocket connection opens when the consumer first iterates
    /// the returned stream; the stream yields `.queued`, zero or
    /// more `.progress(fraction:phase:)`, optionally `.finalizing`,
    /// and terminates with exactly one of `.complete(_:)`,
    /// `.failed(_:)`, or `.cancelled`.
    nonisolated internal func eventStream(
        for handle: JobHandle
    ) -> AsyncThrowingStream<JobEvent, Error> {
        let baseURL = self.baseURL
        let credential = self.credential
        let session = self.session
        let transport = self.transport
        let clock = self.clock
        let jobId = handle.id
        let registry = self.streamRegistry

        return AsyncThrowingStream { continuation in
            // Register the continuation so `detachStream(jobId:)` can
            // finish it cleanly later. Done before the driver task
            // starts so a fast detach can never miss the registration
            // window.
            registry.register(continuation, for: jobId)

            // Driver task (Story 8.5): the WS URL build is async now —
            // OAuth modes fetch the Bearer JWT from the token provider
            // at connection time — so the whole connect sequence lives
            // in one cancellable Task instead of the (synchronous)
            // stream-builder closure. URL/auth failures surface through
            // the continuation on first iteration, exactly as before.
            let driver = Task {
                let wsURL: URL
                do {
                    wsURL = try await Self.buildWebSocketURL(
                        baseURL: baseURL,
                        credential: credential
                    )
                } catch {
                    // buildWebSocketURL only throws ComfyError; if the
                    // stream already terminated this finish is a no-op.
                    continuation.finish(throwing: error)
                    return
                }

                let webSocketTask = session.webSocketTask(with: wsURL)
                webSocketTask.resume()

                await withTaskCancellationHandler {
                    await Self.runReadLoop(
                        webSocketTask: webSocketTask,
                        transport: transport,
                        jobId: jobId,
                        clock: clock,
                        continuation: continuation
                    )
                } onCancel: {
                    // Mirrors the pre-8.5 onTermination behavior: close
                    // the socket deterministically instead of relying on
                    // receive() honoring task cancellation.
                    webSocketTask.cancel(with: .normalClosure, reason: nil)
                }
            }

            continuation.onTermination = { @Sendable reason in
                driver.cancel()
                registry.unregister(jobId: jobId)
                if case .cancelled = reason {
                    // FR23 cooperative cancel: fire the best-effort
                    // server-side cancel POST. Detached so the
                    // termination closure returns immediately. The
                    // `.finished` reason (set by `detachStream(jobId:)`)
                    // intentionally skips this branch so a transport
                    // swap does not abort the user's running job.
                    Task.detached {
                        await transport.cancelJob(id: jobId)
                    }
                }
            }
        }
    }

    /// Build the WebSocket connection URL for one stream, injecting the
    /// credential as a `?token=` query parameter (Comfy Cloud's WebSocket
    /// endpoint does not support custom headers — the whole URL is
    /// therefore sensitive and MUST never be logged, NFR-S2).
    ///
    /// `.apiKey`: the key rides as `?token=` — byte-identical to
    /// Story 1.5. `.oauth` / `.oauthRefreshable` (Story 8.5): the Bearer
    /// JWT rides as `?token=` via the same mechanism, fetched from the
    /// token provider at connection time. If the provider fails, this
    /// throws and the stream finishes with an auth error rather than
    /// opening an unauthenticated socket.
    ///
    /// WS-level auth expiry / reconnect is Story 8.8 territory — a
    /// mid-session WS auth failure triggers the WS→polling handoff
    /// (Story 4.4), and the polling path goes through
    /// `Transport.withAuthRetry`, which handles the 401-refresh cycle.
    ///
    /// `internal` + `static` so unit tests can assert the URL contract
    /// for every credential mode directly: `URLSessionWebSocketTask`
    /// bypasses custom `URLProtocol`s, so capturing the URL through a
    /// stubbed session is not possible without live network.
    ///
    /// Every error thrown is a `ComfyError`: provider failures that are
    /// not already `ComfyError` (and empty tokens) map to `.authInvalid`,
    /// an unbuildable URL to `.unknown(underlying: URLError(.badURL))`.
    internal static func buildWebSocketURL(
        baseURL: URL,
        credential: ComfyCredential,
        clientID: String = UUID().uuidString
    ) async throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("ws"),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = (baseURL.scheme == "http") ? "ws" : "wss"
        var queryItems = [
            URLQueryItem(name: "clientId", value: clientID)
        ]
        switch credential {
        case .apiKey(let key):
            // Byte-identical to Story 1.5 — the key rides as ?token=.
            queryItems.append(URLQueryItem(name: "token", value: key))
        case .oauth(let tokenProvider),
             .oauthRefreshable(let tokenProvider, _, _, _):
            do {
                let token = try await tokenProvider()
                // Same empty-token guard as Transport.applyAuth — an
                // empty `?token=` would surface as an opaque server
                // rejection instead of a typed auth failure.
                guard !token.isEmpty else { throw ComfyError.authInvalid }
                queryItems.append(URLQueryItem(name: "token", value: token))
            } catch let e as ComfyError {
                throw e
            } catch {
                throw ComfyError.authInvalid
            }
        }
        components?.queryItems = queryItems
        guard let wsURL = components?.url else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        return wsURL
    }

    /// The WebSocket read loop. Runs inside the inner Task spawned
    /// by `eventStream(for:)`. Yields `.queued` once, then translates
    /// frames into `JobEvent`s until the stream reaches a terminal
    /// state. Always finishes the continuation before returning.
    private static func runReadLoop(
        webSocketTask: URLSessionWebSocketTask,
        transport: Transport,
        jobId: String,
        clock: any Clock<Duration>,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        let startTime = Date()

        // cursor-reviews fix #5: defer the synthesized FR21 `.queued`
        // event until the WebSocket actually delivers a frame. The
        // previous implementation yielded `.queued` here — *before*
        // calling `webSocketTask.receive()` for the first time — so
        // an immediate connect/auth failure (TLS, 401, DNS) would
        // still surface as `.queued → .failed(...)` from the UI's
        // point of view. That's misleading: the job was never
        // actually queued by the server. By gating `.queued` on the
        // first successful `receive()` we guarantee that any code
        // path leading to `.queued` is one in which the server
        // accepted the connection and started talking to us. The
        // `didEmitQueued` latch keeps the FR21 contract intact —
        // exactly one `.queued` per stream, before any other event.
        var didEmitQueued = false

        var bufferedImageRefs: [OutputFileRef] = []
        var bufferedVideoRefs: [OutputFileRef] = []
        var lastNodeName: String = "queued"
        var lastFraction: Double = 0.0
        var didEmitFinalizing = false

        do {
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                }
                let frameText: String
                switch message {
                case .string(let text):
                    frameText = text
                case .data(let data):
                    // Comfy Cloud sends JSON text frames for status
                    // messages. Binary frames carry preview images
                    // and are out of scope for Story 1.5; ignore
                    // them and continue reading.
                    if let asString = String(data: data, encoding: .utf8) {
                        frameText = asString
                    } else {
                        continue
                    }
                @unknown default:
                    continue
                }

                guard let frameData = frameText.data(using: .utf8) else {
                    continue
                }
                let envelope: WebSocketFrameEnvelope
                do {
                    envelope = try JSONDecoder().decode(
                        WebSocketFrameEnvelope.self,
                        from: frameData
                    )
                } catch {
                    // Unknown frame shape; ignore and keep reading.
                    // The SDK never crashes on unrecognized server
                    // frames.
                    continue
                }

                // Filter for our prompt id where possible — Comfy
                // Cloud's WebSocket may multiplex multiple jobs on
                // one connection, so frames for *other* jobs should
                // be skipped.
                if let dataDict = envelope.data?.value as? [String: Any],
                   let promptId = dataDict["prompt_id"] as? String,
                   promptId != jobId {
                    continue
                }

                switch envelope.type {
                case "executing":
                    if let dataDict = envelope.data?.value as? [String: Any] {
                        if let node = dataDict["node"] as? String, !node.isEmpty {
                            lastNodeName = node
                            if !didEmitFinalizing {
                                continuation.yield(.progress(
                                    fraction: lastFraction,
                                    phase: phaseLabel(for: node)
                                ))
                            }
                        } else {
                            // `node == nil` means workflow execution
                            // has finished, but outputs may still be
                            // buffering.
                            if !didEmitFinalizing {
                                continuation.yield(.finalizing)
                                didEmitFinalizing = true
                            }
                        }
                    }
                case "progress":
                    if let dataDict = envelope.data?.value as? [String: Any] {
                        let valueDouble = (dataDict["value"] as? Double)
                            ?? (dataDict["value"] as? Int).map(Double.init)
                        let maxDouble = (dataDict["max"] as? Double)
                            ?? (dataDict["max"] as? Int).map(Double.init)
                        if let value = valueDouble, let maxVal = maxDouble, maxVal > 0 {
                            let raw = value / maxVal
                            let clampedFraction = clamped(raw)
                            lastFraction = clampedFraction
                            continuation.yield(.progress(
                                fraction: clampedFraction,
                                phase: phaseLabel(for: lastNodeName)
                            ))
                        }
                    }
                case "executed":
                    if let rawDict = envelope.data?.value,
                       let frameJSON = try? JSONSerialization.data(withJSONObject: rawDict),
                       let executed = try? JSONDecoder().decode(
                        ExecutedFrameData.self,
                        from: frameJSON
                       ) {
                        if let images = executed.output?.images {
                            bufferedImageRefs.append(contentsOf: images)
                        }
                        if let gifs = executed.output?.gifs {
                            bufferedVideoRefs.append(contentsOf: gifs)
                        }
                        if let videos = executed.output?.videos {
                            bufferedVideoRefs.append(contentsOf: videos)
                        }
                    }
                case "execution_success":
                    // cursor-reviews fix #6: a Comfy Cloud workflow can
                    // emit `execution_success` with **no** preceding
                    // `executed` frames if every output node was muted
                    // or skipped. The previous code would yield
                    // `.complete(WorkflowOutput(files: []))` in that
                    // case — which silently violates the documented
                    // `WorkflowOutput.files` contract ("non-empty"
                    // per architecture.md §Public Surface) and lands
                    // an empty result in the gallery. Surface a typed
                    // failure instead, so the FR21 state machine
                    // routes the user to the error path rather than
                    // a blank success cell. The sentinel rides on
                    // `ComfyError.unknown(underlying:)` per FR26.
                    if bufferedImageRefs.isEmpty && bufferedVideoRefs.isEmpty {
                        continuation.yield(.failed(.unknown(underlying: EmptyOutputError())))
                        continuation.finish()
                        return
                    }
                    if !didEmitFinalizing {
                        continuation.yield(.finalizing)
                        didEmitFinalizing = true
                    }
                    do {
                        var files: [WorkflowOutput.OutputFile] = []
                        for ref in bufferedImageRefs {
                            // BE-1606: wrap each output download in the
                            // transient-retry helper so a stale-connection
                            // blip on the just-resumed socket (ECONNRESET
                            // et al.) does not surface as a permanent
                            // `.failed` — the download retries up to
                            // `PollingFallback.outputFetchMaxAttempts`
                            // times before giving up. Non-transient errors
                            // propagate immediately, unchanged.
                            let (data, mime) = try await PollingFallback.withTransientRetry {
                                try await transport.downloadView(
                                    filename: ref.filename,
                                    subfolder: ref.subfolder,
                                    type: ref.type
                                )
                            }
                            files.append(.image(data, mimeType: mime))
                        }
                        for ref in bufferedVideoRefs {
                            let ext = (ref.filename as NSString).pathExtension
                            let url = try await PollingFallback.withTransientRetry {
                                try await transport.downloadViewToTempFile(
                                    filename: ref.filename,
                                    subfolder: ref.subfolder,
                                    type: ref.type,
                                    suggestedExtension: ext.isEmpty ? "mp4" : ext
                                )
                            }
                            files.append(.video(url: url))
                        }
                        let duration = Date().timeIntervalSince(startTime)
                        let output = WorkflowOutput(
                            files: files,
                            durationSeconds: duration,
                            jobId: jobId
                        )
                        continuation.yield(.complete(output))
                        continuation.finish()
                        return
                    } catch {
                        // After exhausting retries (or on a non-transient
                        // error), surface the failure as before.
                        let translated = Transport.translate(error)
                        SDKLog.wsOutputBuildFailed(error: translated, jobId: jobId)
                        continuation.yield(.failed(translated))
                        continuation.finish()
                        return
                    }
                case "execution_error":
                    // cursor-reviews fix #2: preserve server diagnostics.
                    // Decode `ExecutionErrorFrameData` and stash the
                    // `exception_type` / `exception_message` (plus the
                    // failing node id) into a typed `JobExecutionError`
                    // sentinel. The sentinel rides through the public
                    // taxonomy on `ComfyError.unknown(underlying:)` so
                    // Epic 4 `ErrorPresentation` can pattern-match on
                    // the type without re-parsing free-text strings.
                    // If the frame doesn't decode at all (server returned
                    // an unknown shape) we still surface a typed sentinel
                    // — never a generic `URLError(.badServerResponse)`,
                    // which is what this branch did before the fix.
                    var execError = JobExecutionError(
                        exceptionType: nil,
                        exceptionMessage: nil,
                        nodeType: nil
                    )
                    if let rawDict = envelope.data?.value,
                       let frameJSON = try? JSONSerialization.data(withJSONObject: rawDict),
                       let decoded = try? JSONDecoder().decode(
                        ExecutionErrorFrameData.self,
                        from: frameJSON
                       ) {
                        execError = JobExecutionError(
                            exceptionType: decoded.exceptionType,
                            exceptionMessage: decoded.exceptionMessage,
                            nodeType: decoded.nodeType
                        )
                    }
                    SDKLog.wsExecutionError(jobId: jobId)
                    continuation.yield(.failed(.unknown(underlying: execError)))
                    continuation.finish()
                    return
                case "execution_interrupted":
                    continuation.yield(.cancelled)
                    continuation.finish()
                    return
                default:
                    // Unknown frame type — ignore and keep reading.
                    continue
                }
            }

            // Loop exited via `Task.isCancelled`. Yield `.cancelled`
            // exactly once and finish.
            continuation.yield(.cancelled)
            continuation.finish()
        } catch is CancellationError {
            continuation.yield(.cancelled)
            continuation.finish()
        } catch {
            let translated = Transport.translate(error)
            if case .cancelled = translated {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
            // Story 4.4 Task 4 — WebSocket → polling handoff (AC2).
            // Transient network failures mid-stream should not surface
            // to the consumer. Instead, spin up a `PollingFallback`
            // seeded with what this WebSocket session has already
            // emitted, and continue yielding events through the same
            // `AsyncThrowingStream` continuation. The consumer never
            // observes the transport switch.
            if PollingFallback.isTransient(translated) {
                SDKLog.wsReadLoopError(error: translated, jobId: jobId, handingOffToPolling: true)
                let lastPhase = didEmitQueued ? phaseLabel(for: lastNodeName) : nil
                await Self.handOffToPolling(
                    transport: transport,
                    jobId: jobId,
                    startTime: startTime,
                    lastEmittedPhase: lastPhase,
                    lastEmittedFraction: lastFraction,
                    hasEmittedQueued: didEmitQueued,
                    hasEmittedFinalizing: didEmitFinalizing,
                    clock: clock,
                    continuation: continuation
                )
                return
            }
            SDKLog.wsReadLoopError(error: translated, jobId: jobId, handingOffToPolling: false)
            continuation.yield(.failed(translated))
            continuation.finish()
        }
    }

    // MARK: - WebSocket → polling handoff (Story 4.4 Task 4, AC2)

    /// Bridge this WebSocket session's emitted state into a fresh
    /// `PollingFallback` stream, forwarding every event through the
    /// same continuation. Called only after the read loop has already
    /// exited via a transient error — otherwise the consumer would
    /// see duplicate `.queued` or missing phase transitions.
    ///
    /// Seeding (FR21 de-duplication contract):
    ///   - `hasEmittedQueued` prevents the poll loop from re-emitting
    ///     the synthesized `.queued` the WebSocket already sent.
    ///   - `lastEmittedPhase` / `lastEmittedFraction` prevent the first
    ///     `.progress` from being a duplicate of the last WS frame.
    ///   - `hasEmittedFinalizing` prevents re-emitting `.finalizing`
    ///     when the WS dropped right before `execution_success`.
    private static func handOffToPolling(
        transport: Transport,
        jobId: String,
        startTime: Date,
        lastEmittedPhase: String?,
        lastEmittedFraction: Double,
        hasEmittedQueued: Bool,
        hasEmittedFinalizing: Bool,
        clock: any Clock<Duration>,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        let polling = PollingFallback(
            transport: transport,
            jobId: jobId,
            startTime: startTime,
            clock: clock
        )
        do {
            for try await event in polling.eventStream(
                lastEmittedPhase: lastEmittedPhase,
                lastEmittedFraction: lastEmittedFraction,
                hasEmittedQueued: hasEmittedQueued,
                hasEmittedFinalizing: hasEmittedFinalizing
            ) {
                continuation.yield(event)
                switch event {
                case .complete, .failed, .cancelled:
                    continuation.finish()
                    return
                default:
                    continue
                }
            }
            continuation.finish()
        } catch {
            continuation.yield(.failed(.unknown(underlying: error)))
            continuation.finish()
        }
    }
}

/// Clamp a fraction to `[0, 1]`. Defense in depth — server frames
/// have produced out-of-range values in the wild, and the FR21 UI
/// state machine assumes its inputs are always in range.
///
/// cursor-reviews fix #4: also collapse `NaN` and `±infinity` to
/// `0.0`. `min`/`max` propagate `NaN` instead of clamping it (IEEE
/// 754 rules), so a server frame with `value == 0` and `max == 0`
/// — or any other arithmetic that produces `NaN` upstream — would
/// previously slip through this helper and land in the UI as a
/// `NaN` progress fraction, violating the documented `[0.0, 1.0]`
/// contract on `JobEvent.progress(fraction:phase:)`. The
/// `isFinite` guard belongs here (not at the call site) because
/// `clamped(_:)` *is* the contract enforcement point — the rule is
/// "anything that survives this function is in `[0, 1]`".
fileprivate func clamped(_ x: Double) -> Double {
    guard x.isFinite else { return 0.0 }
    return min(1.0, max(0.0, x))
}

/// Sentinel error carrying server-side execution diagnostics from a
/// Comfy Cloud `execution_error` WebSocket frame. Wrapped in
/// `ComfyError.unknown(underlying:)` so the public taxonomy stays
/// stable; Story 4.1 will reclassify well-known `exceptionType` values
/// (e.g. `OutOfMemoryError`, `ContentFiltered`) into typed `ComfyError`
/// cases by pattern-matching on this struct.
///
/// All three fields are optional because the server frame schema does
/// not guarantee any of them — the SDK never crashes on a malformed
/// frame, but it also never silently swallows whatever context *did*
/// arrive (cursor-reviews fix #2).
///
/// The struct carries no API key, no workflow JSON, and no URLs —
/// only server-provided diagnostic strings that the consumer's
/// `ErrorPresentation` layer can surface or hash for telemetry per
/// the NFR-S2 / FR26 contract on `ComfyError`.
struct JobExecutionError: Error {
    let exceptionType: String?
    let exceptionMessage: String?
    let nodeType: String?
}

/// Sentinel thrown when a Comfy Cloud `execution_success` frame
/// arrives but no `executed` frames preceded it — meaning every
/// output node was muted, skipped, or produced nothing. Wrapped in
/// `ComfyError.unknown(underlying:)` so the public taxonomy stays
/// stable; Story 4.1 will reclassify this into a typed `ComfyError`
/// case (probably alongside `.jobFailed(phase:)`).
///
/// cursor-reviews fix #6 — the previous behavior silently yielded a
/// `WorkflowOutput` with an empty `files` array, which violates the
/// non-empty `files` contract documented on `WorkflowOutput`.
struct EmptyOutputError: Error {}

/// Coarse phase label derived from a Comfy Cloud node id. Maps known
/// node names to canonical phase labels (`"queued"`, `"sampling"`,
/// `"vae_decode"`, etc.). Unknown nodes fall back to `"executing"` so
/// the UI never sees raw graph internals — phase strings are
/// transport-agnostic per architecture.md §Naming Patterns line 256.
fileprivate func phaseLabel(for node: String) -> String {
    let lower = node.lowercased()
    if lower.contains("ksampler") || lower.contains("sampler") {
        return "sampling"
    }
    if lower.contains("vae") {
        return "vae_decode"
    }
    if lower.contains("clip") || lower.contains("encode") {
        return "encoding"
    }
    if lower.contains("save") || lower.contains("preview") {
        return "saving"
    }
    if lower == "queued" {
        return "queued"
    }
    return "executing"
}
