# DeviceKit iOS

[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg?style=flat-square)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2016.0+-blue.svg?style=flat-square)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-lightgrey.svg?style=flat-square)](LICENSE)

Control any iOS device or simulator over a simple JSON-RPC API. Tap, swipe, stream video, inspect the UI, from any language, over localhost.

> **This is the Busymate fork** (`serebano/devicekit-ios`, forked from [`mobile-next/devicekit-ios`](https://github.com/mobile-next/devicekit-ios)). It is the DeviceKit control engine + native H.264 broadcast mirror consumed by the [busymate-devtools](https://github.com/serebano/busymate-devtools) Android/iOS farm (`cli/bmfarm`, pinned via `DEVICEKIT_PIN`). Fork-specific work is tracked as bmfarm issue numbers in the [CHANGELOG](CHANGELOG.md). `main` = the latest shipped implementation (control server 0.0.27 + BroadcastMirror 60fps).

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Starting the Server](#starting-the-server)
  - [JSON-RPC API](#json-rpc-api)
  - [Streaming Endpoints](#streaming-endpoints)
- [Architecture](#architecture)
- [Building](#building)
- [Testing](#testing)
- [Communication](#communication)
- [License](#license)

## What You Can Build

- **Interactive automation** — Tap, swipe, long-press, type text, press hardware buttons (home, lock, volume)
- **App control** — Launch, terminate, and detect the foreground app by bundle ID
- **Live screen visibility** — MJPEG streaming from the runner (`GET /mjpeg`), plus native hardware **H.264 @60fps** via the [BroadcastMirror](#broadcast-mirror-farm-add-on) ReplayKit extension
- **UI inspection** — Full accessibility tree dumps for element targeting
- **Screenshots** — PNG or JPEG capture with configurable quality
- **System control** — Get/set orientation, open URLs, query screen size and scale
- **Broadcast video** — ReplayKit extension streams native **H.264 (Baseline, Annex-B)** over raw TCP `127.0.0.1:12005` (audio port `:12006` reserved, not yet implemented)
- **Flexible transport** — JSON-RPC 2.0 over WebSocket or HTTP, from any language

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 16.0           |
| Swift    | 5.9            |
| Xcode    | 15.0+          |

## Installation

### Building from Source

```bash
# Clone the repository
git clone https://github.com/serebano/devicekit-ios.git
cd devicekit-ios

# Install dependencies
brew install xcbeautify

# Build unsigned IPA for real devices
make ipa-unsigned

# Build XCUITest runner for simulators
make sim-zip
```

### Build Targets

| Target | Output | Description |
|--------|--------|-------------|
| `make ipa-unsigned` | `build/export/devicekit-ios-unsigned.ipa` | Unsigned IPA for arm64 devices |
| `make app-zip` | `build/export/devicekit-ios-Runner.app.zip` | Raw **device-independent** Runner.app (build once, sign per-device — the farm prebuilt path, bmfarm #1592) |
| `make sim-zip-arm64` | `build/export/devicekit-ios-Sim-arm64.zip` | Simulator runner (Apple Silicon) |
| `make sim-zip-x86_64` | `build/export/devicekit-ios-Sim-x86_64.zip` | Simulator runner (Intel) |
| `make sim-zip` | Both simulator zips | arm64 + x86_64 |
| `make lint` | — | Run SwiftLint |
| `make clean` | — | Remove build artifacts |

## Quick Start

Once the server is running at `127.0.0.1:12004`, make your first call:

```bash
curl -X POST http://127.0.0.1:12004/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"device.screenshot","params":{ "format": "png" },"id":1}'
```

Returns a base64-encoded PNG of the current screen.

## Usage

### Starting the Server

DeviceKit runs as an XCUITest. Once installed and launched on a device or simulator, it starts a server on `127.0.0.1:12004`.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVICEKIT_LISTEN_PORT` | `12004` | JSON-RPC server port |
| `DEVICEKIT_LISTEN_HOST` | `127.0.0.1` | Bind address for the JSON-RPC server |
| `DEVICEKIT_READY_TIMEOUT_MS` | `3000` | Hard timeout for the `/ready` readiness probe's single `device.info` round-trip. On timeout `/ready` degrades to `{ ready: false, reason: "device.info timed out — testmanagerd not wired yet" }` rather than hanging (bmfarm #1603) |

**Endpoints** — all served over the single JSON-RPC HTTP/WebSocket server on `:12004`:

| Endpoint | Protocol | Description |
|----------|----------|-------------|
| `GET /ws` | WebSocket | JSON-RPC 2.0 |
| `POST /rpc` | HTTP | JSON-RPC 2.0 |
| `GET /health` | HTTP | Liveness — constant `OK` the instant the socket binds (does **not** prove control works) |
| `GET /ready` | HTTP | Readiness — reads a thread-safe cache filled by one real `device.info` (testmanagerd) round-trip and returns `{ ok, ready, port, udid, name, build }`; HTTP 200 only when control is actually wired (bmfarm #1603/#1647) |
| `GET /mjpeg` | HTTP | MJPEG screen stream (see [Streaming Endpoints](#streaming-endpoints)) |
| `POST /shutdown` | HTTP | Graceful shutdown — stops the server so a fresh runner can take the single testmanagerd slot |

> Native H.264 is **not** an HTTP route on this server (the in-runner H264 HTTP path was split out upstream in 0.0.19). Hardware H.264 @60fps is served by the separate [BroadcastMirror](#broadcast-mirror-farm-add-on) ReplayKit extension over raw TCP `:12005`.

### JSON-RPC API

All methods follow the [JSON-RPC 2.0](https://www.jsonrpc.org/specification) specification.

```json
{
  "jsonrpc": "2.0",
  "method": "device.io.tap",
  "params": { "x": 100, "y": 200, "deviceId": "any" },
  "id": 1
}
```

#### Input

| Method | Description |
|--------|-------------|
| `device.io.tap` | Tap at (x, y) coordinates |
| `device.io.swipe` | Swipe from (x1, y1) to (x2, y2) |
| `device.io.longpress` | Long press at (x, y) for a duration |
| `device.io.gesture` | Multi-finger gesture with press/move/release actions |
| `device.io.text` | Type text into the focused field |
| `device.io.button` | Press a hardware button (`home`, `lock`, `volumeUp`, `volumeDown`) |

#### Device

| Method | Description |
|--------|-------------|
| `device.info` | Get screen size and scale factor |
| `device.io.orientation.get` | Get current orientation (`PORTRAIT` / `LANDSCAPE`) |
| `device.io.orientation.set` | Set orientation to `PORTRAIT` or `LANDSCAPE` |
| `device.url` | Open a URL |

#### Apps

| Method | Description |
|--------|-------------|
| `device.apps.launch` | Launch an app by bundle ID |
| `device.apps.terminate` | Terminate an app by bundle ID |
| `device.apps.foreground` | Get the foreground app's bundle ID, name, and PID |

#### Inspection

| Method | Description |
|--------|-------------|
| `device.dump.ui` | Return the full accessibility view hierarchy |
| `device.screenshot` | Capture a screenshot (base64 PNG/JPEG) |

### Streaming Endpoints

#### MJPEG

```
GET /mjpeg?fps=10&quality=25&scale=100
```

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `fps` | 10 | 1–60 | Frames per second |
| `quality` | 25 | 1–100 | JPEG quality (%) |
| `scale` | 100 | 10–100 | Scale factor (%) |

MJPEG is the runner's own screen stream (screenshot-based, fps-capped by XCUITest). For native hardware H.264 at 60fps, use the separate [BroadcastMirror](#broadcast-mirror-farm-add-on) ReplayKit extension (`:12005`, raw TCP).

## Testing

Tests run against a live XCUITest server on a booted simulator. You need one simulator running — the test harness picks the first booted device automatically.

```bash
# Install test dependencies (one-time)
cd tests && npm install && cd ..

# Run tests with code coverage
make test-coverage

# View coverage report as HTML
make coverage-html
```

## Architecture

```
devicekit-ios/
  DeviceKit/                    # SwiftUI host app (broadcast-picker helper)
  DeviceKitTests/               # XCUITest runner = the automation server (:12004)
    JSONRPC/                    #   JSON-RPC 2.0 dispatcher + method handlers (tap/swipe/text/button/orientation/url/apps/dump/screenshot)
    Streamer/MJPEG/             #   MJPEG HTTP screen stream (GET /mjpeg)
    XCTest/                     #   Private-API wrappers (touch synthesis, accessibility, RunnerDaemonProxy)
  BroadcastMirror/              # ReplayKit broadcast H.264 @60fps over :12005 (farm add-on)
    Core/                       #   SwiftPM package: pure, unit-tested logic (AnnexB / DownscalePolicy / BitratePolicy / FramePacer)
    Host/                       #   Lean host app that opens the system broadcast picker (net.busymate.mirror)
    Upload/                     #   RPBroadcastSampleHandler → VideoToolbox H.264 → loopback :12005 (net.busymate.mirror.upload)
```

The `DeviceKitTests` runner is the JSON-RPC control server (the only artifact the farm installs by default). `BroadcastMirror/` is a self-contained companion module with its own project generator, ASC-API signing recipe, and build script — see [`BroadcastMirror/README.md`](BroadcastMirror/README.md).

## Dependencies

- [FlyingFox](https://github.com/swhitty/FlyingFox) — Lightweight HTTP and WebSocket server (the `:12004` control server)

## Communication

This fork's changes exist to serve the Busymate farm — fork-specific issues and coordination live in [busymate-devtools](https://github.com/serebano/busymate-devtools) (the CHANGELOG references bmfarm issue numbers). For the upstream project, [open an issue at `mobile-next/devicekit-ios`](https://github.com/mobile-next/devicekit-ios/issues).

## License

DeviceKit iOS is released under the [Functional Source License 1.1, Apache 2.0 Future License](LICENSE).

---

## Broadcast Mirror (farm add-on)

[`BroadcastMirror/`](BroadcastMirror/) is a first-class companion module: a
ReplayKit **broadcast upload extension** + a lean host app that stream a farm
phone's screen as native hardware **H.264 (Baseline, Annex-B)** over
`127.0.0.1:12005` — far above the XCUITest-screenshot frame-rate ceiling. It has
its own project generator, ASC-API provisioning recipe, hard-timeout-guarded
build script, deviceless unit tests (`cd BroadcastMirror/Core && swift test`),
and a documented `:12005` wire contract for the off-device producer. See
[`BroadcastMirror/README.md`](BroadcastMirror/README.md).
