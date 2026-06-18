# ComfySwiftSDK

A thin Swift client for the public [Comfy Cloud](https://cloud.comfy.org) API: submit a
workflow, stream its events, and the stream hands you the outputs. Powers the Comfy Go
iOS app.

> **Status:** pre-release, private. Not yet licensed for external use. Extracted from the
> Comfy-iOS app repository.

## Surface

- **Submit** a workflow — `ComfyCloudClient`, `WorkflowRequest` / `WorkflowInput`
- **Stream** job events (queued / running / progress / done) — `JobHandle` / `JobEvent`
- **Outputs** arrive as the terminal event — `WorkflowOutput`
- **Auth** — "Sign in with Comfy" OAuth (authorization code + PKCE) — `ComfyCredential`,
  `OAuthAuthorizationRequest` / `OAuthTokenResponse`

Requires iOS 17 / macOS 14.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/Comfy-Org/ComfySwiftSDK.git", branch: "main")
```
