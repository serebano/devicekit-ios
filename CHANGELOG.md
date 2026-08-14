<!--
This fork (serebano/devicekit-ios) ships two release lines, interleaved below newest-first:
  • the `0.0.X` control-server runner (DeviceKitTests, the JSON-RPC server on :12004)
  • the `broadcast-mirror-vX.Y.Z` BroadcastMirror companion module (native H.264 over :12005)
Fork-specific entries reference busymate-devtools (`bmfarm #NNNN`) issue numbers; upstream
(mobile-next) entries keep their original PR links.
-->

## [broadcast-mirror-v0.2.0](https://github.com/serebano/devicekit-ios/releases/tag/broadcast-mirror-v0.2.0) (2026-08-14)
* Feat: BroadcastMirror **60fps** native H.264 (bmfarm #1659). Bumps the ReplayKit broadcast upload extension to a 60fps default encode rate (`BroadcastConfig.fps = 60`, up from 30 in v0.1.0) — genuine display-framebuffer frames, hardware-encoded and VSync-paced, far above the XCUITest-screenshot ceiling. Adds an Xcode-26 unsigned build recipe. The release attaches a prebuilt `BroadcastMirror.app.zip` (host app + embedded upload extension) alongside the standard runner artifacts.
* The `:12005` wire contract: raw **Annex-B** H.264 elementary stream (Baseline, no B-frames, realtime), SPS/PPS in-band and re-emitted before every IDR, one forced IDR on connect (join latency ≤ ~1 frame), multi-client fan-out, `TCP_NODELAY`. Source resolution is capped at `maxLongEdge` (default 1920, aspect-preserved) and downscaled through a pooled `VTPixelTransferSession` to stay under the ReplayKit ~50 MB extension memory ceiling; `MemoryPressureGuard` decimates the encode rate under pressure rather than losing the session.
* Audio port `:12006` is **reserved but not implemented** (iOS ships no system Opus encoder; the `SampleHandler` audio path is a clean no-op).

## [broadcast-mirror-v0.1.0](https://github.com/serebano/devicekit-ios/releases/tag/broadcast-mirror-v0.1.0) (2026-08-14)
* Feat: **BroadcastMirror** — the production build of the proven spike (bmfarm #1659). A first-class companion module (`BroadcastMirror/`): a ReplayKit **broadcast upload extension** (`net.busymate.mirror.upload`, `RPBroadcastSampleHandler` → VideoToolbox H.264 → loopback `127.0.0.1:12005`) + a lean **host app** (`net.busymate.mirror`) that opens the system broadcast picker so the farm can start the mirror hands-off. Ships a SwiftPM `Core/` package of pure, deviceless-unit-tested logic (AnnexB / DownscalePolicy / BitratePolicy / FramePacer), an `.xcodeproj` generator (`project.rb`), an App-Store-Connect-API provisioning recipe (`ascprov.rb`), and a hard-timeout-guarded `build.sh`. Default encode rate 30fps.

## [0.0.27](https://github.com/serebano/devicekit-ios/releases/tag/0.0.27) (2026-08-14)
* Fix: bind the on-device `:12004` control server OFF the `@MainActor` (bmfarm #1647). The class is `@MainActor`, so the non-detached `Task { server.run() }` inherited the MainActor executor and the FlyingFox `socket.bind()` was starved whenever XCTest's test-session bootstrap held the main thread with a synchronous, non-suspending accessibility call (`springboard.frame`/`device.info` — no suspension point). The runner then emitted NEITHER `DEVICEKIT_READY` NOR `DEVICEKIT_ERR` — a silent bind hang (LIVE on BMDEV8, iOS 17.5.1: testmanagerd authorized:true, reboots delivered, yet `:12004` returned TCP RST). `Task.detached` runs the accept loop on the global concurrent executor, so the bind + `waitUntilListening` complete regardless of the main thread; route handlers still hop to the main thread at request time. 0.0.26's FIX-1 had moved only the `/ready` PROBE off the MainActor, not the BIND itself.

## [0.0.26](https://github.com/serebano/devicekit-ios/releases/tag/0.0.26) (2026-08-12)
* Fix: NON-BLOCKING `/ready` + emit `DEVICEKIT_READY` after `waitUntilListening` (bmfarm #1603). FIX-1: `/ready` now reads a thread-safe readiness **cache** (filled by a single-flight background prober from one `device.info` round-trip with a hard `DEVICEKIT_READY_TIMEOUT_MS` timeout, default 3000ms) instead of hopping onto the `@MainActor` per request — a stuck testmanagerd degrades the cache to `{ ready: false, reason: "device.info timed out — testmanagerd not wired yet" }` instead of serialising every `/ready`/`/rpc`/`/ws` behind it (the ~13s hang). FIX-2: emit the `DEVICEKIT_READY` stderr line **after** `server.waitUntilListening()` (FlyingFox 0.22.0) so a consumer never flips ready before the socket actually accepts. `/health` stays a constant `OK` for backward compatibility with older bmfarm builds.

## [0.0.25](https://github.com/serebano/devicekit-ios/releases/tag/0.0.25) (2026-08-12)
* Build: attach the raw **device-independent** `devicekit-ios-Runner.app.zip` to each release (bmfarm #1592). The runner `.app` is device-independent, so the farm can build it ONCE and sign+install it per-device (embed an explicit manual profile + re-sign) instead of a full per-device `xcodebuild build-for-testing`, killing the per-device Apple automatic-signing provisioning wedge (`make app-zip`). Releases now carry `devicekit-ios-Runner.app.zip` alongside the `.ipa` and the simulator zips.

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
