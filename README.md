<div align="center">

<img src="assets/logo.svg" alt="Comfy Cloud" width="130"/>

<h1>ComfySwiftSDK</h1>

<p>
  <strong>The Swift client for <a href="https://cloud.comfy.org">Comfy Cloud</a>.</strong><br/>
  Submit a workflow, stream its events, get your outputs — in a few lines of <code>async</code>/<code>await</code>.
</p>

</div>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9"></a>
  <a href="#"><img src="https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Platforms"></a>
  <a href="#"><img src="https://img.shields.io/badge/SwiftPM-compatible-brightgreen?style=for-the-badge&logo=swift&logoColor=white" alt="SwiftPM"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-lightgrey?style=for-the-badge" alt="License: Apache 2.0"></a>
  <a href="https://cloud.comfy.org"><img src="https://img.shields.io/badge/Comfy_Cloud-cloud.comfy.org-211927?style=for-the-badge" alt="Comfy Cloud"></a>
</p>

---

A thin, dependency-free Swift client for the [Comfy Cloud](https://cloud.comfy.org) API. You hand it a
ComfyUI workflow graph; it submits the job, streams the lifecycle back to you as a typed
`AsyncThrowingStream`, and the terminal event hands you the finished media. No callbacks, no delegates,
no Combine — just structured concurrency. It powers the **Comfy Go** iOS app.

## What it does

- **Submit** a workflow — `ComfyCloudClient.submit(_:)` with a `WorkflowRequest`
- **Stream** job events — `events(for:)` yields `.queued` → `.progress` → `.finalizing` → `.complete` / `.failed` / `.cancelled`
- **Receive** outputs — images arrive inline, videos stream to a temp file, both via `WorkflowOutput`
- **Reattach** after a network drop or app relaunch — `reattach(to:)` / `reattach(promptId:)`
- **Authenticate** — an API key, or "Sign in with Comfy" OAuth (authorization-code + PKCE)

## Requirements

| | |
|---|---|
| Swift | 5.9+ |
| Platforms | iOS 17+ · macOS 14+ |
| Dependencies | None (Foundation + CryptoKit only) |

## Install

Add the package in Xcode (**File → Add Package Dependencies…**) or in your `Package.swift`:

```swift
.package(url: "https://github.com/Comfy-Org/ComfySwiftSDK.git", branch: "main")
```

…then list `ComfySwiftSDK` as a dependency of your target.

## Quick start

```swift
import ComfySwiftSDK

// 1. Construct a client. (API key shown here; OAuth is also supported — see below.)
let client = ComfyCloudClient(apiKey: "your-api-key")

// 2. Submit a ComfyUI API-format workflow graph. The SDK posts it verbatim.
let request = WorkflowRequest(workflowJSON: myWorkflowGraph)
let job = try await client.submit(request)

// 3. Stream the job's lifecycle until it reaches a terminal event.
for try await event in client.events(for: job) {
    switch event {
    case .queued:
        print("queued")
    case .progress(let fraction, let phase):
        print("\(phase): \(Int(fraction * 100))%")
    case .finalizing:
        print("downloading output…")
    case .complete(let output):
        for file in output.files {
            switch file {
            case .image(let data, let mimeType):
                print("image: \(data.count) bytes (\(mimeType))")
            case .video(let url):
                print("video: \(url.path)")
            }
        }
    case .failed(let error):
        print("failed: \(error)")
    case .cancelled:
        print("cancelled")
    }
}
```

Cancellation is cooperative: cancel the consuming `Task` and the SDK fires a best-effort server-side
cancel, then yields a final `.cancelled` event.

## Authentication

Two modes, both behind the same `ComfyCloudClient`:

```swift
// API key
let client = ComfyCloudClient(apiKey: "your-api-key")

// "Sign in with Comfy" OAuth (authorization-code + PKCE, no client secret on device)
let client = ComfyCloudClient(credential: .oauth(tokenProvider: { await myKeychain.accessToken() }))
```

For the OAuth handshake, `ComfyCloudClient.buildAuthorizationRequest()` mints the PKCE material and the
authorize URL; you drive the browser step (`ASWebAuthenticationSession`) and pass the callback code to
`exchangeAuthorizationCode(_:codeVerifier:)`. Credentials are held privately and are never logged,
returned, or interpolated into error messages.

## Status

**Pre-1.0.** The SDK is battle-tested by the Comfy Go iOS app, builds clean, and ships with a full test
suite. The public API may still shift before a tagged 1.0 — pin to a commit if you need
stability today. Feedback on the surface is what we're looking for at this stage.

## Contributing

Contributions are very welcome — issues, bug reports, and PRs all help. If you're building something on
Comfy Cloud in Swift and hit a rough edge, [open an issue](https://github.com/Comfy-Org/ComfySwiftSDK/issues);
real-world usage is the best guide for where this SDK should go next.

A few pointers:

- `swift build` and `swift test` should both pass before you open a PR.
- Keep the public surface small and `async`/`await`-native — no callbacks, delegates, or Combine.
- New error conditions go through the `ComfyError` taxonomy rather than leaking transport details.

For anything substantial, open an issue first so we can talk through the approach.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright © Comfy Org.
