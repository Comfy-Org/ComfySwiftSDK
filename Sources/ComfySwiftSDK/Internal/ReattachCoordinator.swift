import Foundation

internal actor ReattachCoordinator {

    private let transport: Transport
    private let clock: any Clock<Duration>

    internal init(
        transport: Transport,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.clock = clock
    }

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

    /// Fixed delay schedule for the catch-up status retrier: 250 ms before the
    /// second attempt, 750 ms before the third. Two attempts' worth of pauses →
    /// a three-attempt budget, matching the original hand-rolled loop.
    private static let catchUpRetryDelays: [Duration] = [.milliseconds(250), .milliseconds(750)]

    private static func fetchJobStatusWithTransientRetry(
        transport: Transport,
        id: String,
        clock: any Clock<Duration>
    ) async throws -> JobDetailResponse {
        try await PollingFallback.withTransientRetry(
            delays: catchUpRetryDelays,
            sleep: { duration in try await clock.sleep(for: duration) },
            body: { try await transport.fetchJobStatus(id: id) }
        )
    }

    private static func runReattach(
        handle: JobHandle,
        transport: Transport,
        clock: any Clock<Duration>,
        hasEmittedFinalizing: Bool,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        let startTime = Date()

        let dto: JobDetailResponse
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

        switch dto.status {
        case .completed:
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

        case .failed:
            let phase = PollingFallback.derivePhase(from: dto)
            continuation.yield(.failed(.jobFailed(phase: phase)))
            continuation.finish()
            return

        case .cancelled:
            continuation.yield(.cancelled)
            continuation.finish()
            return

        case .pending, .inProgress, .unknown:
            break
        }

        var lastEmittedPhase: String?
        var lastEmittedFraction: Double = 0.0
        var hasEmittedQueued = false
        let didEmitFinalizing = hasEmittedFinalizing

        switch dto.status {
        case .pending:
            continuation.yield(.queued)
            hasEmittedQueued = true
            lastEmittedPhase = "queued"

        case .inProgress:
            if hasEmittedFinalizing {
                continuation.yield(.finalizing)
                hasEmittedQueued = true
            } else {
                continuation.yield(.queued)
                hasEmittedQueued = true
                let phase = PollingFallback.derivePhase(from: dto)
                let fraction = PollingFallback.deriveFraction(from: dto)
                continuation.yield(.progress(fraction: fraction, phase: phase))
                lastEmittedPhase = phase
                lastEmittedFraction = fraction
            }

        case .completed, .failed, .cancelled, .unknown:
            continuation.yield(.queued)
            hasEmittedQueued = true
        }

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
            continuation.finish()
        } catch {
            continuation.yield(.failed(.unknown(underlying: error)))
            continuation.finish()
        }
    }
}
