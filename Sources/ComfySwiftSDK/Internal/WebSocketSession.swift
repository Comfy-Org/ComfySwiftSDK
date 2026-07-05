import Foundation

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

internal actor WebSocketSession {

    private let session: URLSession
    private let baseURL: URL
    private let credential: ComfyCredential
    private let transport: Transport
    private let clock: any Clock<Duration>
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

    nonisolated internal func detachStream(jobId: String) {
        streamRegistry.detach(jobId: jobId)
    }

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
            registry.register(continuation, for: jobId)

            let driver = Task {
                let wsURL: URL
                do {
                    wsURL = try await Self.buildWebSocketURL(
                        baseURL: baseURL,
                        credential: credential
                    )
                } catch {
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
                    webSocketTask.cancel(with: .normalClosure, reason: nil)
                }
            }

            continuation.onTermination = { @Sendable reason in
                driver.cancel()
                registry.unregister(jobId: jobId)
                PollingFallback.fireCancelJobIfCancelled(reason, transport: transport, jobId: jobId)
            }
        }
    }

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
            queryItems.append(URLQueryItem(name: "token", value: key))
        case .oauth(let tokenProvider),
             .oauthRefreshable(let tokenProvider, _, _, _):
            do {
                let token = try await tokenProvider()
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

    private static func runReadLoop(
        webSocketTask: URLSessionWebSocketTask,
        transport: Transport,
        jobId: String,
        clock: any Clock<Duration>,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        let startTime = Date()

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
                    continue
                }

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
                                    phase: PhaseLabel.forNode(node)
                                ))
                            }
                        } else {
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
                                phase: PhaseLabel.forNode(lastNodeName)
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
                        let output = try await PollingFallback.assembleOutput(
                            imageRefs: bufferedImageRefs,
                            videoRefs: bufferedVideoRefs,
                            transport: transport,
                            startTime: startTime,
                            jobId: jobId
                        )
                        continuation.yield(.complete(output))
                        continuation.finish()
                        return
                    } catch {
                        let translated = Transport.translate(error)
                        SDKLog.wsOutputBuildFailed(error: translated, jobId: jobId)
                        continuation.yield(.failed(translated))
                        continuation.finish()
                        return
                    }
                case "execution_error":
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
                    continue
                }
            }

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
            if PollingFallback.isTransient(translated) {
                SDKLog.wsReadLoopError(error: translated, jobId: jobId, handingOffToPolling: true)
                let lastPhase = didEmitQueued ? PhaseLabel.forNode(lastNodeName) : nil
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

fileprivate func clamped(_ x: Double) -> Double {
    guard x.isFinite else { return 0.0 }
    return min(1.0, max(0.0, x))
}

struct JobExecutionError: Error {
    let exceptionType: String?
    let exceptionMessage: String?
    let nodeType: String?
}

struct EmptyOutputError: Error {}
