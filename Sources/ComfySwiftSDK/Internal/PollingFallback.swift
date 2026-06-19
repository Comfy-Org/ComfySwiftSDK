//
//  PollingFallback.swift
//  ComfySwiftSDK
//
//  Polling fallback for the WebSocket transport. Used when the
//  WebSocket either drops mid-stream (see `WebSocketSession`'s
//  fallback handoff) or is unavailable from the start (cellular
//  networks, restricted proxies — PRD risk table line 397). Also
//  used by `ReattachCoordinator` as the continuation transport
//  when the reattach flow cannot re-establish a WebSocket.
//
//  Transport-agnostic contract (architecture.md §Naming Patterns
//  line 256): the consumer of the `AsyncThrowingStream<JobEvent, Error>`
//  cannot tell whether a frame came from WebSocket or polling. Every
//  `JobEvent` case yielded here is identical in shape to the matching
//  case yielded by `WebSocketSession`.
//
//  Polling cadence:
//    - Active-state poll interval: ~1s (matches the WebSocket's
//      effective update frequency for the FR21 ticker).
//    - Exponential backoff on transport errors: 2s → 4s → 8s cap.
//      The backoff counter resets on a successful poll.
//
//  De-duplication:
//    - The loop tracks the last-emitted phase label and skips
//      `.progress` emissions whose phase + fraction are unchanged.
//    - `.queued`/`.finalizing`/`.complete`/`.failed`/`.cancelled`
//      are terminal or one-shot — each is emitted at most once.
//    - A `lastEmittedPhase` seed lets the WebSocket handoff path
//      (Story 4.4 Task 4) avoid re-emitting a phase the UI
//      already saw.
//
//  Logging: credential-free error classification only via `SDKLog`
//  (see SDKLog.swift). ComfyError case name + jobId at give-up and
//  output-assembly failure paths. NEVER credential / body / raw error.
//
//  Story 4.4.
//

import Foundation

/// Polling-based event stream for an in-flight Comfy Cloud job.
/// Hits `GET /api/prompt/{prompt_id}` via `Transport` at ~1s cadence
/// and translates the response into the same `JobEvent` values the
/// WebSocket transport yields.
internal actor PollingFallback {

    /// Active-state poll interval (matches the WebSocket's effective
    /// FR21 ticker cadence).
    static let activePollInterval: Duration = .milliseconds(1000)

    /// Exponential backoff ladder used on transport errors. After the
    /// last entry the loop keeps polling at the max interval until
    /// either the server recovers or the consumer cancels.
    static let backoffLadder: [Duration] = [
        .milliseconds(2000),
        .milliseconds(4000),
        .milliseconds(8000)
    ]

    private let transport: Transport
    private let jobId: String
    private let startTime: Date
    /// Clock injected so tests can drive time forward without real
    /// sleeps. Not part of any public contract.
    private let clock: any Clock<Duration>

    internal init(
        transport: Transport,
        jobId: String,
        startTime: Date = Date(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.jobId = jobId
        self.startTime = startTime
        self.clock = clock
    }

    /// Open a cold `AsyncThrowingStream<JobEvent, Error>` that polls
    /// the server until the job reaches a terminal status.
    ///
    /// - Parameters:
    ///   - lastEmittedPhase: the last `JobEvent` phase the consumer
    ///     has already observed. Used for de-duplication — if the
    ///     first poll returns the same phase, the loop skips emitting
    ///     it. Pass `nil` for a fresh stream (no prior phase seen).
    ///   - lastEmittedFraction: the last `.progress` fraction the
    ///     consumer has observed. Seeded alongside `lastEmittedPhase`
    ///     so the WS→polling handoff and `ReattachCoordinator`
    ///     catch-up don't re-emit the progress value the UI already
    ///     has. Defaults to `0.0` for a fresh stream.
    ///   - hasEmittedQueued: whether the consumer has already seen
    ///     `.queued`. Matches `WebSocketSession`'s "at most one
    ///     `.queued`" contract on FR21.
    nonisolated internal func eventStream(
        lastEmittedPhase: String? = nil,
        lastEmittedFraction: Double = 0.0,
        hasEmittedQueued: Bool = false,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        let transport = self.transport
        let jobId = self.jobId
        let startTime = self.startTime
        let clock = self.clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                await Self.runPollLoop(
                    transport: transport,
                    jobId: jobId,
                    startTime: startTime,
                    clock: clock,
                    initialLastPhase: lastEmittedPhase,
                    initialLastFraction: lastEmittedFraction,
                    initialQueuedEmitted: hasEmittedQueued,
                    initialFinalizingEmitted: hasEmittedFinalizing,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable reason in
                task.cancel()
                // Story 4.7, AC7: mirror WebSocketSession's behavior —
                // fire best-effort server-side cancel when the consumer
                // task is cancelled. Detached so the termination closure
                // returns immediately.
                if case .cancelled = reason {
                    Task.detached {
                        await transport.cancelJob(id: jobId)
                    }
                }
            }
        }
    }

    // MARK: - Poll loop

    private static func runPollLoop(
        transport: Transport,
        jobId: String,
        startTime: Date,
        clock: any Clock<Duration>,
        initialLastPhase: String?,
        initialLastFraction: Double,
        initialQueuedEmitted: Bool,
        initialFinalizingEmitted: Bool,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        var lastPhase: String? = initialLastPhase
        var lastFraction: Double = initialLastFraction
        var didEmitQueued: Bool = initialQueuedEmitted
        var didEmitFinalizing: Bool = initialFinalizingEmitted
        var backoffIndex: Int = 0
        // cursor-reviews Fix C: tolerate eventually-consistent success.
        // The server may flip `status` to "success" a poll or two before
        // the `outputs` map is populated. Treat that as non-terminal and
        // keep polling (capped) rather than immediately failing with
        // `EmptyOutputError`, which would kill the stream for a job
        // that did complete correctly.
        var successWithoutOutputsRetries: Int = 0
        let successWithoutOutputsMaxRetries: Int = 8

        while !Task.isCancelled {
            let dto: JobStatusDTO
            do {
                dto = try await transport.fetchJobStatus(id: jobId)
                backoffIndex = 0 // success resets the backoff ladder
            } catch let error as ComfyError {
                // Transient transport errors back off; permanent
                // errors (auth, server rejection) terminate.
                if isTransient(error) {
                    let delay = backoffDelay(for: backoffIndex)
                    backoffIndex = min(backoffIndex + 1, backoffLadder.count - 1)
                    do {
                        try await clock.sleep(for: delay)
                    } catch {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }
                    continue
                } else {
                    SDKLog.pollingGaveUp(error: error, jobId: jobId)
                    continuation.yield(.failed(error))
                    continuation.finish()
                    return
                }
            } catch {
                let wrapped = ComfyError.unknown(underlying: error)
                SDKLog.pollingGaveUp(error: wrapped, jobId: jobId)
                continuation.yield(.failed(wrapped))
                continuation.finish()
                return
            }

            // Translate DTO → JobEvent(s).
            switch dto.status.lowercased() {
            case "queued", "pending":
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                    lastPhase = "queued"
                }

            case "running", "executing", "in_progress":
                // A4 fix: reset the eventually-consistent success retry
                // budget if the server reverts from "success" to "running"
                // (observed during high-load status oscillation).
                successWithoutOutputsRetries = 0
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                }
                let phase = derivePhase(from: dto)
                let fraction = deriveFraction(from: dto)
                // De-duplicate: only emit if phase or fraction changed
                // relative to the last emission.
                if phase != lastPhase || fraction != lastFraction {
                    continuation.yield(.progress(fraction: fraction, phase: phase))
                    lastPhase = phase
                    lastFraction = fraction
                }

            case "success", "completed", "succeeded":
                if !didEmitFinalizing {
                    continuation.yield(.finalizing)
                    didEmitFinalizing = true
                }
                // cursor-reviews Fix C: eventually-consistent success.
                // If the server returned "success" but the outputs map
                // hasn't been populated yet, keep polling instead of
                // failing. Capped so we don't loop forever on a truly
                // empty job.
                if !hasOutputRefs(in: dto) {
                    if successWithoutOutputsRetries < successWithoutOutputsMaxRetries {
                        successWithoutOutputsRetries += 1
                        do {
                            try await clock.sleep(for: activePollInterval)
                        } catch {
                            continuation.yield(.cancelled)
                            continuation.finish()
                            return
                        }
                        continue
                    }
                    // Exhausted retries — surface the empty-output failure.
                    SDKLog.pollingEmptyOutputExhausted(jobId: jobId)
                    continuation.yield(.failed(.unknown(underlying: EmptyOutputError())))
                    continuation.finish()
                    return
                }
                do {
                    let output = try await buildOutput(
                        from: dto,
                        transport: transport,
                        startTime: startTime,
                        jobId: jobId
                    )
                    continuation.yield(.complete(output))
                    continuation.finish()
                    return
                } catch let error as ComfyError {
                    SDKLog.pollingOutputAssemblyFailed(error: error, jobId: jobId)
                    continuation.yield(.failed(error))
                    continuation.finish()
                    return
                } catch {
                    let wrapped = ComfyError.unknown(underlying: error)
                    SDKLog.pollingOutputAssemblyFailed(error: wrapped, jobId: jobId)
                    continuation.yield(.failed(wrapped))
                    continuation.finish()
                    return
                }

            case "error", "failed":
                let phase = derivePhase(from: dto)
                continuation.yield(.failed(.jobFailed(phase: phase)))
                continuation.finish()
                return

            case "cancelled", "canceled":
                continuation.yield(.cancelled)
                continuation.finish()
                return

            default:
                // Unknown status — conservative: keep polling.
                break
            }

            // Sleep before the next poll. Active cadence (1s) when
            // the server is responding successfully; backoff ladder
            // takes over above on transport errors.
            do {
                try await clock.sleep(for: activePollInterval)
            } catch {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
        }

        // Task cancelled cooperatively.
        continuation.yield(.cancelled)
        continuation.finish()
    }

    // MARK: - Helpers

    /// Transient errors drive exponential backoff rather than
    /// terminating the stream. Everything else is surfaced as
    /// `.failed` so the consumer can route to the error sheet.
    static func isTransient(_ error: ComfyError) -> Bool {
        switch error {
        case .network, .offline, .timeout:
            return true
        case .rateLimited:
            return true
        case .authInvalid, .authExpired, .contentFiltered,
             .serverRejected, .jobFailed, .cancelled, .unknown:
            return false
        }
    }

    /// Pull the current backoff delay from the ladder, clamped to the
    /// last rung (further failures keep polling at the max interval).
    static func backoffDelay(for index: Int) -> Duration {
        let clamped = min(max(index, 0), backoffLadder.count - 1)
        return backoffLadder[clamped]
    }

    /// Derive a short transport-agnostic phase label from the polled
    /// DTO. Never a raw Comfy Cloud node name — that would leak the
    /// workflow graph into the UI.
    static func derivePhase(from dto: JobStatusDTO) -> String {
        if let node = dto.node, !node.isEmpty {
            return phaseLabel(forNode: node)
        }
        switch dto.status.lowercased() {
        case "queued", "pending":
            return "queued"
        case "success", "completed", "succeeded":
            return "saving"
        default:
            return "executing"
        }
    }

    /// Compute a clamped `[0, 1]` fraction from the DTO's progress
    /// bucket. Mirrors the `WebSocketSession`'s fraction-clamping
    /// contract (defense in depth against malformed server frames).
    static func deriveFraction(from dto: JobStatusDTO) -> Double {
        guard let value = dto.progress?.value,
              let max = dto.progress?.max,
              max > 0 else {
            return 0.0
        }
        let raw = value / max
        guard raw.isFinite else { return 0.0 }
        return min(1.0, Swift.max(0.0, raw))
    }

    /// Whether the DTO carries at least one image / gif / video ref
    /// in its `outputs` map. Used by the poll loop's success branch to
    /// distinguish "job done, assets ready" from "server flipped status
    /// a beat before assets materialized" (cursor-reviews Fix C).
    static func hasOutputRefs(in dto: JobStatusDTO) -> Bool {
        guard let outputs = dto.outputs else { return false }
        for (_, payload) in outputs {
            if let images = payload.images, !images.isEmpty { return true }
            if let gifs = payload.gifs, !gifs.isEmpty { return true }
            if let videos = payload.videos, !videos.isEmpty { return true }
        }
        return false
    }

    /// Build a `WorkflowOutput` from a terminal `success` DTO by
    /// downloading every referenced output via Transport.
    ///
    /// Each individual download is wrapped in `withTransientRetry` so a
    /// stale-connection blip on the just-resumed socket does not surface
    /// as a permanent failure — the output fetch retries (up to
    /// `outputFetchMaxAttempts` times) before giving up.
    static func buildOutput(
        from dto: JobStatusDTO,
        transport: Transport,
        startTime: Date,
        jobId: String
    ) async throws -> WorkflowOutput {
        var imageRefs: [OutputFileRef] = []
        var videoRefs: [OutputFileRef] = []
        for (_, payload) in dto.outputs ?? [:] {
            if let images = payload.images {
                imageRefs.append(contentsOf: images)
            }
            if let gifs = payload.gifs {
                videoRefs.append(contentsOf: gifs)
            }
            if let videos = payload.videos {
                videoRefs.append(contentsOf: videos)
            }
        }

        if imageRefs.isEmpty && videoRefs.isEmpty {
            throw ComfyError.unknown(underlying: EmptyOutputError())
        }

        var files: [WorkflowOutput.OutputFile] = []
        for ref in imageRefs {
            let (data, mime) = try await withTransientRetry {
                try await transport.downloadView(
                    filename: ref.filename,
                    subfolder: ref.subfolder,
                    type: ref.type
                )
            }
            files.append(.image(data, mimeType: mime))
        }
        for ref in videoRefs {
            let ext = (ref.filename as NSString).pathExtension
            let url = try await withTransientRetry {
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
        return WorkflowOutput(
            files: files,
            durationSeconds: duration,
            jobId: jobId
        )
    }

    /// Maximum number of attempts for a transient-error retry on output
    /// fetch. One initial attempt + up to two retries = three total.
    static let outputFetchMaxAttempts: Int = 3

    /// Retry `body` up to `outputFetchMaxAttempts` times when it throws
    /// a transient `ComfyError`. Non-transient errors and non-`ComfyError`
    /// throws propagate immediately on the first occurrence. On the last
    /// attempt the transient error also propagates so the caller can
    /// surface a `.failed` event — we never loop forever.
    ///
    /// The retry is intentionally small (3 attempts, no real sleep) to
    /// match the "stale-connection blip" scenario: the first call on a
    /// just-resumed socket often fails with `ECONNRESET`; the second
    /// typically succeeds once the OS has re-established the underlying
    /// TCP session. If the network is genuinely down the polling loop
    /// above already handles prolonged outages with exponential backoff.
    static func withTransientRetry<T>(
        body: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0 ..< outputFetchMaxAttempts {
            do {
                return try await body()
            } catch let error as ComfyError where isTransient(error) {
                lastError = error
                // Short pause only after the first failure — gives the
                // OS a moment to re-establish the socket before retry 2.
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
                }
                continue
            } catch {
                // Non-transient ComfyError or unknown error: surface immediately.
                throw error
            }
        }
        throw lastError!
    }

    /// Coarse phase label derived from a Comfy Cloud node id. Mirrors
    /// the `WebSocketSession.phaseLabel(for:)` helper so the two
    /// transports produce identical phase strings for the same node.
    static func phaseLabel(forNode node: String) -> String {
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
}
