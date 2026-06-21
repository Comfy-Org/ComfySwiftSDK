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

    @Test(.disabled("Requires live Comfy Cloud key, seeded comfy-ios client (Story 8.1 gate), and >15min session"))
    func silent_refresh_across_token_expiry() async throws {
        let apiKey = ProcessInfo.processInfo.environment["COMFY_API_KEY"] ?? ""
        try #require(!apiKey.isEmpty, "Set COMFY_API_KEY to run this test")
    }
}
