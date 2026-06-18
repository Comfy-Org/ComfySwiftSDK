//
//  SmokeIntegrationTests.swift
//  ComfySwiftSDKTests
//
//  Story 1.5 AC #14 — disabled-by-default integration smoke test that
//  exercises the full `submit` → `events(for:)` round-trip against a
//  real Comfy Cloud account. The test is gated three ways:
//
//    1. `.disabled` annotation so a normal `xcodebuild test` skips it
//       without intervention.
//    2. `try #require(!apiKey.isEmpty, ...)` short-circuit if the
//       `COMFY_API_KEY` environment variable is unset.
//    3. The repo never contains a real key. The dev runs the test
//       once locally with `COMFY_API_KEY=sk-... xcodebuild test ...`
//       (or by setting the env var on the scheme in Xcode), captures
//       the result in the Story 1.5 Debug Log References section,
//       and re-disables the test before commit.
//
//  This is the only thing in Story 1.5 that exercises the WebSocket
//  transport against a live server; everything else is unit-level.
//
//  Story 1.5.
//

import Testing
import Foundation
import ComfySwiftSDK

@Suite("ComfySwiftSDK Smoke Integration")
struct SmokeIntegrationTests {

    @Test(.disabled("Requires live Comfy Cloud key — run manually with COMFY_API_KEY env var"))
    func text_to_image_round_trip() async throws {
        let apiKey = ProcessInfo.processInfo.environment["COMFY_API_KEY"] ?? ""
        try #require(
            !apiKey.isEmpty,
            "Set COMFY_API_KEY in scheme environment to run this test"
        )

        let client = ComfyCloudClient(apiKey: apiKey)

        // Minimal text→image workflow JSON for Comfy Cloud. The exact
        // node graph below is the smallest viable text→image graph
        // (CheckpointLoaderSimple → CLIPTextEncode × 2 → EmptyLatentImage
        // → KSampler → VAEDecode → SaveImage). The Story 1.5 dev should
        // adjust the model name to whatever's currently available on
        // the dev's Comfy Cloud account before running.
        let workflow: [String: Any] = [
            "3": [
                "class_type": "KSampler",
                "inputs": [
                    "seed": 42,
                    "steps": 10,
                    "cfg": 7.0,
                    "sampler_name": "euler",
                    "scheduler": "normal",
                    "denoise": 1.0,
                    "model": ["4", 0],
                    "positive": ["6", 0],
                    "negative": ["7", 0],
                    "latent_image": ["5", 0]
                ]
            ],
            "4": [
                "class_type": "CheckpointLoaderSimple",
                "inputs": ["ckpt_name": "v1-5-pruned-emaonly.safetensors"]
            ],
            "5": [
                "class_type": "EmptyLatentImage",
                "inputs": ["width": 512, "height": 512, "batch_size": 1]
            ],
            "6": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "text": "a photo of a cat astronaut in space, detailed",
                    "clip": ["4", 1]
                ]
            ],
            "7": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "text": "blurry, low quality",
                    "clip": ["4", 1]
                ]
            ],
            "8": [
                "class_type": "VAEDecode",
                "inputs": [
                    "samples": ["3", 0],
                    "vae": ["4", 2]
                ]
            ],
            "9": [
                "class_type": "SaveImage",
                "inputs": [
                    "filename_prefix": "ComfySwiftSDK_smoke",
                    "images": ["8", 0]
                ]
            ]
        ]

        let request = WorkflowRequest(workflowJSON: workflow, inputs: [
            .text("a photo of a cat astronaut in space, detailed")
        ])

        let handle = try await client.submit(request)

        var sawQueued = false
        var sawProgress = false
        var sawComplete = false
        var imageBytes: Data?
        var lastError: ComfyError?

        for try await event in client.events(for: handle) {
            switch event {
            case .queued:
                sawQueued = true
            case .progress(let fraction, _):
                sawProgress = true
                #expect(fraction >= 0.0 && fraction <= 1.0)
            case .finalizing:
                continue
            case .complete(let output):
                sawComplete = true
                if case .image(let data, _)? = output.files.first {
                    imageBytes = data
                }
            case .failed(let err):
                lastError = err
            case .cancelled:
                Issue.record("Unexpected cancellation in smoke test")
            }
        }

        #expect(lastError == nil, "Smoke run failed: \(String(describing: lastError))")
        #expect(sawQueued, "Smoke run never yielded .queued")
        #expect(sawProgress, "Smoke run never yielded .progress")
        #expect(sawComplete, "Smoke run never yielded .complete")
        #expect(imageBytes != nil, "Smoke run completed but had no image bytes")
    }

    // Story 8.5 AC9 — live silent-refresh check across a >15-minute
    // session (the access-token TTL), so a real proactive refresh and a
    // real `grant_type=refresh_token` rotation are observed end-to-end.
    @Test(.disabled("Requires live Comfy Cloud key, seeded comfy-ios client (Story 8.1 gate), and >15min session"))
    func silent_refresh_across_token_expiry() async throws {
        let apiKey = ProcessInfo.processInfo.environment["COMFY_API_KEY"] ?? ""
        try #require(!apiKey.isEmpty, "Set COMFY_API_KEY to run this test")
        // TODO: wire oauthRefreshable credential with real Keychain reads once
        // Story 8.6 (first-run UX wiring) lands — the credential construction
        // requires a signed-in session. Placeholder body only.
    }
}
