# AGENTS.md

Guidance for AI coding agents working in this repository. Humans: see
[`README.md`](README.md).

ComfySwiftSDK is a **Swift Package** — the thin, dependency-free Swift client
behind the Comfy Go iOS app. There is no `package.json`, no npm scripts, and no
`format:check`; the toolchain is Swift Package Manager. Verify everything with
the Swift toolchain, not a JavaScript one.

## Build & test

Run both from the package root before opening a PR:

```sh
swift build
swift test --no-parallel
```

- `--no-parallel` is required: the test target's `URLProtocol`-stub tests share
  a process-global handler behind a blocking lock, and Swift Testing's default
  cross-suite parallelism deadlocks on it. CI runs the same command.
- The test target imports the **Swift Testing** framework, which ships with the
  Swift 6 / Xcode 16 toolchain. Use a toolchain new enough to bundle it.

Both steps build and run **on the macOS host** — this package targets
macOS 14, so no iOS simulator or device is needed. Prefer the narrowest thing
that proves your change (a single `swift test` filter), then the full suite.

## Platform guarding

The package supports **iOS 17+ and macOS 14+** from a single target, and the
build/test that gate a PR run on macOS. So any iOS-only API you reach for
(`UIKit`, `UIApplication`, etc.) **must** be guarded so the macOS build still
compiles:

```swift
#if os(iOS)
// iOS-only API
#endif
```

## Import boundary

The core `ComfySwiftSDK` target imports only `Foundation`, `CryptoKit`, and
`os` — never `SwiftUI`, `SwiftData`, `Photos`, `Combine`, `UIKit`, or
`Security`. This boundary is enforced over `Sources/ComfySwiftSDK/` by
`ImportBoundaryTests` under `swift test`; a new import outside the allowed set
is a test failure, not a style nit. (The separate `ComfyAuthKit` target, which
wraps `AuthenticationServices`, is intentionally outside this boundary.) Keep
the public
surface small and `async`/`await`-native (no callbacks, delegates, or Combine),
and route new error conditions through the `ComfyError` taxonomy.

## Before you open a PR

- **Self-review your full diff** as an adversarial reviewer of your own change:
  confirm the build and tests are green, and that every changed line is
  intended. Automated review coverage on this repo is light — the self-review
  is the real gate.
- **This repo is public.** Never commit secrets, API keys, tokens, internal
  hostnames, or private infrastructure details in code, comments, commit
  messages, or PR text. Credentials must stay out of logs and error messages.
