//
//  ReattachCoordinator.swift
//  ComfySwiftSDK
//
//  Reattach flow for the `ComfyCloudClient.reattach(to:)` public API.
//  Consumed by the app when `ConnectivityMonitor` flips back to online
//  mid-generation — the controller hands the still-live `JobHandle`
//  back to the SDK and asks for a fresh `AsyncThrowingStream<JobEvent, Error>`
//  that picks up the in-flight job wherever it currently is.
//
//  Contract (Story 4.4 AC3):
//    1. Fetch the current job status via a single `GET /api/prompt/{id}`.
//    2. If the job has already terminated, yield the terminal event
//       (`.complete` / `.failed` / `.cancelled`) and finish.
//    3. If the job is still queued or running, synthesize a catch-up
//       `.queued` (always) and — if running — a `.progress` whose
//       fraction and phase reflect the server's current position. This
//       keeps the FR21 UI state machine in sync before any new events
//       arrive.
//    4. Continue the event stream via `PollingFallback`, seeded with
//       the phase we just synthesized so the first real poll response
//       does not re-emit a duplicate `.progress`.
//
//  Why polling (not WebSocket) for the continuation:
//    The Comfy Cloud WebSocket endpoint has no documented protocol for
//    resuming a mid-flight job — connecting mid-flight may produce no
//    catch-up frames at all. Polling gives us a deterministic resume
//    that does not depend on server-side state we cannot observe. The
//    Task 4 WebSocket → polling handoff in `WebSocketSession` covers
//    the orthogonal case (WS drops during an active stream); reattach
//    is a user-initiated resume and needs the reliable path.
//
//  Transport-agnostic output (architecture.md §Naming Patterns
//  line 256): the consumer of the returned stream cannot tell that
//  this is a reattach — every `JobEvent` case yielded here is shape-
//  identical to the matching case yielded by `WebSocketSession`.
//
//  No logging (SDK observability is deferred per Story 1.5 Dev Notes).
//
//  Story 4.4.
//

import Foundation

/// Drives the `reattach(to:)` public API: fetches current job status,
/// emits a synthetic catch-up event, then continues via polling until
/// terminal.
internal actor ReattachCoordinator {

    private let transport: Transport
    /// Clock injected so tests can drive time forward without real
    /// sleeps when the polling continuation kicks in.
    private let clock: any Clock<Duration>

    internal init(
        transport: Transport,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.clock = clock
    }

    /// Open a cold `AsyncThrowingStream<JobEvent, Error>` that resumes
    /// an in-flight job's lifecycle. See the file header for the full
    /// contract.
    nonisolated internal func reattach(
        to handle: JobHandle,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        let transport = self.transport
        let clock = self.clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                await Self.runReattach(
                    handle: handle,
                    transport: transport,
                    clock: clock,
                    hasEmittedFinalizing: hasEmittedFinalizing,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Catch-up status fetch with a small bounded retry on *transient*
    /// errors. The first request on a connection the OS just
    /// resumed from suspension often fails — a `.network` -1011
    /// bad-server-response, `.offline`, or `.timeout` — and a retry
    /// typically succeeds once the underlying session is re-established.
    /// Non-transient errors propagate on the first occurrence; the
    /// transient error on the final attempt also propagates, so the
    /// caller still terminates rather than looping forever.
    private static func fetchJobStatusWithTransientRetry(
        transport: Transport,
        id: String,
        clock: any Clock<Duration>
    ) async throws -> JobStatusDTO {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await transport.fetchJobStatus(id: id)
            } catch let error as ComfyError
                where PollingFallback.isTransient(error) && attempt < maxAttempts {
                // Transient blip on a just-resumed connection — back off
                // briefly and retry. The error is intentionally swallowed
                // here; the final-attempt transient propagates instead.
                try await clock.sleep(for: .milliseconds(attempt == 1 ? 250 : 750))
            }
        }
    }

    // MARK: - Reattach body

    private static func runReattach(
        handle: JobHandle,
        transport: Transport,
        clock: any Clock<Duration>,
        hasEmittedFinalizing: Bool,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        let startTime = Date()

        // Step 1 — catch-up fetch. A single HTTP GET, retried a few
        // times on a *transient* failure before giving up. The first
        // request on a socket the OS just resumed from suspension often
        // fails (a `.network` -1011 bad-server-response, `.offline`, or
        // `.timeout`); a retry usually succeeds once the connection is
        // re-established. Without this, a momentary blip on resume
        // falsely terminates a job that is still recoverable.
        // Non-transient failures still terminate immediately.
        let dto: JobStatusDTO
        do {
            dto = try await fetchJobStatusWithTransientRetry(
                transport: transport, id: handle.id, clock: clock
            )
        } catch let error as ComfyError {
            continuation.yield(.failed(error))
            continuation.finish()
            return
        } catch {
            continuation.yield(.failed(.unknown(underlying: error)))
            continuation.finish()
            return
        }

        // Step 2 — if the job has already terminated, emit the terminal
        // event and close. The consumer sees `reattach(to:)` as a
        // one-shot catch-up in this case.
        switch dto.status.lowercased() {
        case "success", "completed", "succeeded":
            do {
                let output = try await PollingFallback.buildOutput(
                    from: dto,
                    transport: transport,
                    startTime: startTime,
                    jobId: handle.id
                )
                continuation.yield(.complete(output))
            } catch let error as ComfyError {
                continuation.yield(.failed(error))
            } catch {
                continuation.yield(.failed(.unknown(underlying: error)))
            }
            continuation.finish()
            return

        case "error", "failed":
            let phase = PollingFallback.derivePhase(from: dto)
            continuation.yield(.failed(.jobFailed(phase: phase)))
            continuation.finish()
            return

        case "cancelled", "canceled":
            continuation.yield(.cancelled)
            continuation.finish()
            return

        default:
            break // active — continue to synthetic catch-up + polling
        }

        // Step 3 — job is still active. Emit synthetic catch-up events
        // so the UI state machine jumps to the server's current phase
        // before any new events arrive.
        var lastEmittedPhase: String?
        var lastEmittedFraction: Double = 0.0
        var hasEmittedQueued = false
        var didEmitFinalizing = hasEmittedFinalizing

        switch dto.status.lowercased() {
        case "queued", "pending":
            continuation.yield(.queued)
            hasEmittedQueued = true
            lastEmittedPhase = "queued"

        case "running", "executing", "in_progress":
            if hasEmittedFinalizing {
                // E2 fix: the UI was already at .finalizing before the
                // connectivity drop. Emitting .queued + .progress here
                // would visually regress the stage. Re-emit .finalizing
                // so the UI stays at the same phase and polling continues
                // from there.
                continuation.yield(.finalizing)
                hasEmittedQueued = true // suppress .queued in polling
            } else {
                // FR21: `.queued` must precede `.progress`. The server has
                // already accepted the job, so we synthesize both — the UI
                // state machine expects this ordering.
                continuation.yield(.queued)
                hasEmittedQueued = true
                let phase = PollingFallback.derivePhase(from: dto)
                let fraction = PollingFallback.deriveFraction(from: dto)
                continuation.yield(.progress(fraction: fraction, phase: phase))
                lastEmittedPhase = phase
                lastEmittedFraction = fraction
            }

        default:
            // Unknown status — conservative: still emit `.queued` so
            // the consumer's FR21 state machine is seeded, then let
            // polling observe the real status.
            continuation.yield(.queued)
            hasEmittedQueued = true
        }

        // Step 4 — continue via polling. Seed with our just-emitted
        // phase + fraction so the first poll response does not re-emit
        // the same `.progress` we synthesized above (cursor-reviews
        // fix — without this seed the poll loop initializes
        // `lastFraction = 0.0` and can duplicate a just-synthesized
        // non-zero fraction).
        let polling = PollingFallback(
            transport: transport,
            jobId: handle.id,
            startTime: startTime,
            clock: clock
        )

        do {
            for try await event in polling.eventStream(
                lastEmittedPhase: lastEmittedPhase,
                lastEmittedFraction: lastEmittedFraction,
                hasEmittedQueued: hasEmittedQueued,
                hasEmittedFinalizing: didEmitFinalizing
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
            // Polling stream finished without a terminal — shouldn't
            // happen, but close the continuation cleanly.
            continuation.finish()
        } catch {
            continuation.yield(.failed(.unknown(underlying: error)))
            continuation.finish()
        }
    }
}
