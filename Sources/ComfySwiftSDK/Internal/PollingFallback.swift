import Foundation

internal actor PollingFallback {

    static let activePollInterval: Duration = .milliseconds(1000)

    static let backoffLadder: [Duration] = [
        .milliseconds(2000),
        .milliseconds(4000),
        .milliseconds(8000)
    ]

    private let transport: Transport
    private let jobId: String
    private let startTime: Date
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
                if case .cancelled = reason {
                    Task.detached {
                        await transport.cancelJob(id: jobId)
                    }
                }
            }
        }
    }

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
        var successWithoutOutputsRetries: Int = 0
        let successWithoutOutputsMaxRetries: Int = 8

        while !Task.isCancelled {
            let dto: JobDetailResponse
            do {
                dto = try await transport.fetchJobStatus(id: jobId)
                backoffIndex = 0
            } catch let error as ComfyError {
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

            switch dto.status.lowercased() {
            case "pending":
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                    lastPhase = "queued"
                }

            case "in_progress":
                successWithoutOutputsRetries = 0
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                }
                let phase = derivePhase(from: dto)
                let fraction = deriveFraction(from: dto)
                if phase != lastPhase || fraction != lastFraction {
                    continuation.yield(.progress(fraction: fraction, phase: phase))
                    lastPhase = phase
                    lastFraction = fraction
                }

            case "completed":
                if !didEmitFinalizing {
                    continuation.yield(.finalizing)
                    didEmitFinalizing = true
                }
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

            case "failed":
                let phase = derivePhase(from: dto)
                continuation.yield(.failed(.jobFailed(phase: phase)))
                continuation.finish()
                return

            case "cancelled":
                continuation.yield(.cancelled)
                continuation.finish()
                return

            default:
                break
            }

            do {
                try await clock.sleep(for: activePollInterval)
            } catch {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
        }

        continuation.yield(.cancelled)
        continuation.finish()
    }

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

    static func backoffDelay(for index: Int) -> Duration {
        let clamped = min(max(index, 0), backoffLadder.count - 1)
        return backoffLadder[clamped]
    }

    static func derivePhase(from dto: JobDetailResponse) -> String {
        switch dto.status.lowercased() {
        case "pending":
            return "queued"
        case "completed":
            return "saving"
        case "failed":
            if let nodeType = dto.executionError?.nodeType, !nodeType.isEmpty {
                return phaseLabel(forNode: nodeType)
            }
            return "executing"
        default:
            return "executing"
        }
    }

    static func deriveFraction(from dto: JobDetailResponse) -> Double {
        return 0.0
    }

    static func hasOutputRefs(in dto: JobDetailResponse) -> Bool {
        guard let outputs = dto.outputs else { return false }
        for (_, payload) in outputs {
            if let images = payload.images, !images.isEmpty { return true }
            if let gifs = payload.gifs, !gifs.isEmpty { return true }
            if let videos = payload.videos, !videos.isEmpty { return true }
        }
        return false
    }

    static func buildOutput(
        from dto: JobDetailResponse,
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

        return try await assembleOutput(
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            transport: transport,
            startTime: startTime,
            jobId: jobId
        )
    }

    /// Downloads the collected output references and assembles the final
    /// `WorkflowOutput`. Shared by the WebSocket success path and the polling
    /// fallback — the two callers collect the refs differently (incremental
    /// `executed`-frame buffering vs. `dto.outputs` extraction) and handle the
    /// empty-refs case on their own, but the download-and-assemble tail is
    /// identical.
    static func assembleOutput(
        imageRefs: [OutputFileRef],
        videoRefs: [OutputFileRef],
        transport: Transport,
        startTime: Date,
        jobId: String
    ) async throws -> WorkflowOutput {
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

    static let outputFetchMaxAttempts: Int = 3

    static func withTransientRetry<T>(
        body: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0 ..< outputFetchMaxAttempts {
            do {
                return try await body()
            } catch let error as ComfyError where isTransient(error) {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                continue
            } catch {
                throw error
            }
        }
        throw lastError!
    }

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
