## [0.0.27](https://github.com/serebano/devicekit-ios/releases/tag/0.0.27) (2026-08-14)
* Fix: bind the on-device `:12004` control server OFF the `@MainActor` (bmfarm #1647). The class is `@MainActor`, so the non-detached `Task { server.run() }` inherited the MainActor executor and the FlyingFox `socket.bind()` was starved whenever XCTest's test-session bootstrap held the main thread with a synchronous, non-suspending accessibility call (`springboard.frame`/`device.info` — no suspension point). The runner then emitted NEITHER `DEVICEKIT_READY` NOR `DEVICEKIT_ERR` — a silent bind hang (LIVE on BMDEV8, iOS 17.5.1: testmanagerd authorized:true, reboots delivered, yet `:12004` returned TCP RST). `Task.detached` runs the accept loop on the global concurrent executor, so the bind + `waitUntilListening` complete regardless of the main thread; route handlers still hop to the main thread at request time. 0.0.26's FIX-1 had moved only the `/ready` PROBE off the MainActor, not the BIND itself.

## [0.0.24](https://github.com/serebano/devicekit-ios/releases/tag/0.0.24) (2026-08-12)
* Feat: deterministic + honest readiness for the busymate-devtools farm (bmfarm #1570 Wave 1):
  * RC1 — machine-visible `DEVICEKIT_READY port=<p> udid=<u> build=<v>` / `DEVICEKIT_ERR <reason>` lines on stderr, so a consumer flips ready in ~1s and fails fast on a real error instead of a blind 60s `/health` race.
  * RC3/RC7 — new `GET /ready` that runs one real `device.info` (testmanagerd) round-trip and returns a structured `{ ok, ready, port, udid, name, build }` (identity carried so a mis-mapped forward is detectable); `/health` stays a constant `OK`.
  * RC5 — supervised bind + run: a transient `EADDRINUSE` re-binds in-process after a short delay (the dying predecessor frees the port) instead of exiting and forcing a 30-40s host relaunch.
  * Build: the release tag is stamped into the runner's `CFBundleShortVersionString` (reported LIVE via `/ready` `build`).

## [0.0.23](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.23) (2026-08-01)
* Fix: support xcode 26.5 by adding two missing testing frameworks ([#57](https://github.com/mobile-next/devicekit-ios/pull/57))

## [0.0.22](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.22) (2026-07-31)
* Fix: correct element position if it belongs to another window (fixes elements within widgets and such) ([#55](https://github.com/mobile-next/devicekit-ios/pull/55))

## [0.0.20](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.20) (2026-06-15)
* Feat: device.io.keys handler for sending key combos ([#51](https://github.com/mobile-next/devicekit-ios/pull/51))

## [0.0.19](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.19) (2026-06-14)
* Refactor: Split H264 streaming code out into a separate repository ([#47](https://github.com/mobile-next/devicekit-ios/pull/47), [#46](https://github.com/mobile-next/devicekit-ios/pull/46))
* Test: Migrate test suite from Mocha to Playwright ([#49](https://github.com/mobile-next/devicekit-ios/pull/49))

## [0.0.18](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.18) (2026-05-04)
* Fix: Prevent XCTest from resetting shouldHaltWhenReceivesControl back to YES on setup

## [0.0.17](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.17) (2026-05-03)
* iOS: Include placeholderValue in source tree element JSON format
* Fix: Prevent test runner from halting on XCTest internal failures (WDA PR #664)
* General: Improve README copy and add GitHub issue templates

## [0.0.16](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.16) (2026-04-16)
* General: Set app version in Info.plist from git tag at build time

## [0.0.13](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.13) (2026-04-15)
* CI: Parallelize IPA and simulator zip builds
* CI: Fail Trivy scan on HIGH/CRITICAL findings

## [0.0.12](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.12) (2026-04-15)
* General: Bump deployment target from iOS 14 to iOS 16 for smaller swift frameworks overhead
* General: Only package XCUITest runner in the .ipa
* Fix: Prevent outputPath override via CodingKeys, make JSONRPCResponse Encodable only
* CI: Add build provenance attestations for release artifacts
* CI: Remove unnecessary brew install for xcbeautify

## [0.0.10](https://github.com/mobile-next/devicekit-ios/releases/tag/0.0.10) (2026-04-12)
* General: Initial public release of DeviceKit iOS
* General: JSON-RPC 2.0 server over HTTP and WebSocket
* General: Health check and graceful shutdown endpoints
* General: Add MJPEG streaming endpoint tests and test infrastructure
* iOS: Tap, swipe, long press, and multi-finger gesture synthesis
* iOS: Text input via system keyboard
* iOS: Hardware button simulation (home, lock, volume)
* iOS: App launch, terminate, and foreground detection
* iOS: Full accessibility tree inspection (UI hierarchy dump)
* iOS: Screenshot capture (PNG/JPEG with configurable quality)
* iOS: Real-time MJPEG screen streaming with configurable fps, quality, and scale
* iOS: Real-time H264 screen streaming with configurable fps, bitrate, quality, and scale
* iOS: ReplayKit broadcast extension with H264 video and Opus audio
* iOS: Device orientation get/set
* iOS: URL opening
* iOS: Device info (screen size, scale)
