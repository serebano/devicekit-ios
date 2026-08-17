# Broadcast Mirror

A ReplayKit **broadcast upload extension** + a lean host app that stream a farm
phone's screen as native hardware **H.264** over a loopback TCP socket. This is the
production build of the proven spike (busymate-devtools #1659): far above the
~25 fps XCUITest-screenshot ceiling, at native ~60 fps delivery paced to a chosen
encode rate.

- **Host app** `net.busymate.mirror` — opens the system broadcast picker
  automatically so the farm can start the mirror hands-off.
- **Upload extension** `net.busymate.mirror.upload` — `RPBroadcastSampleHandler`
  → VideoToolbox H.264 (Baseline, Annex-B) → `0.0.0.0:12005` (USB loopback +,
  as of **v0.3.0**, auth-gated WiFi — see "WiFi transport + auth" below).

## Layout

```
BroadcastMirror/
  Host/            App.swift, BroadcastPicker.swift, Info.plist   (the picker app)
  Upload/          SampleHandler.swift + encoder/scaler/server/config/mem-guard   (the extension)
  Core/            SwiftPM package: pure, unit-tested logic (downscale/annex-b/bitrate/pacer)
  project.rb       generates BroadcastMirror.xcodeproj (2 targets + embed)
  ascprov.rb       provisions App IDs + dev profiles via the App Store Connect API
  build.sh         provision → generate → build+sign → package .ipa (hard-timeout guarded)
```

The `Core/` pure files are compiled **both** into the SwiftPM package (what
`swift test` exercises) **and** directly into the extension target — single source
of truth, never a fork.

## The `:12005` wire contract (for the bmfarm producer / reframer)

Everything below is what the on-device server emits; the producer forwards the
socket off-device (`iproxy 12005` → relay → `h264Sps.ts` reframer → viewer).

| Property        | Value |
|-----------------|-------|
| Transport       | TCP, `0.0.0.0:12005`, one-way (server → client), `TCP_NODELAY`. Loopback (USB `ios forward`) is unchanged; a WiFi client to `<phone_lan_ip>:12005` must first authenticate (below) |
| Payload         | Raw **Annex-B** H.264 elementary stream (start code `00 00 00 01`) |
| Codec / profile | H.264 **Baseline**, no B-frames, realtime |
| Parameter sets  | SPS/PPS **in-band**, re-emitted **before every IDR** |
| Resolution      | Advertised by the SPS. Capped at `maxLongEdge` (default **1920**), aspect-preserved, even dimensions |
| Frame rate      | `fps` (default **30**), paced down from ReplayKit's ~60 |
| On connect      | Server sends cached SPS/PPS immediately, **then forces a fresh IDR** so a late client decodes at the next frame |
| Multi-client    | Multiple simultaneous readers supported. **v0.3.1 (#1763): each client has its OWN bounded queue + writer thread, so a slow/stalled WiFi reader can never backpressure another reader — the concurrent USB (loopback) stream is never degraded.** A stalled/dead socket is dropped (send-timeout eviction / write failure) + reaped |
| Audio           | `:12006` **reserved, not yet implemented** (see below) |

A client should: read the stream, split on start codes, feed SPS/PPS + the next
IDR to the decoder, then decode subsequent slices. Because config precedes every
IDR and an IDR is forced on connect, join latency is one keyframe (≤ ~1 frame).

## WiFi transport + auth (v0.3.0, busymate-devtools #1759)

The server binds **`0.0.0.0:12005`** (all interfaces), so the bmfarm host reaches
the mirror EITHER over USB (`ios forward … 12005` → the on-device `127.0.0.1`) OR
directly over WiFi (`<phone_lan_ip>:12005`). WiFi is a link physically disjoint
from USB, so a usbmux-dark USB brownout no longer blinds the mirror. Binding
`0.0.0.0` KEEPS loopback working, so the existing USB `ios forward` path is
byte-for-byte unaffected.

A `0.0.0.0` H.264 stream on a shared LAN is not open — every **non-loopback**
connection is gated by a shared-token handshake:

| Peer | Requirement |
|------|-------------|
| Loopback `127.0.0.0/8` (USB `ios forward`) | **Token-exempt.** Only code already on the device can reach `127.0.0.1`, so USB is trusted (the pre-v0.3.0 behaviour). |
| Non-loopback (WiFi/LAN) | Must send **`AUTH <token>\n`** (ASCII line, `\n`-terminated, ≤512 B) as the FIRST bytes, within `authTimeoutSeconds` (3 s), BEFORE any frames. |

**Handshake framing.** After `accept()`, a non-loopback peer runs on its own
thread (never blocking `accept()`): the server reads one `\n`-terminated line
(bounded 512 B, `SO_RCVTIMEO` 3 s), requires the literal prefix `AUTH ` (5 bytes,
`0x41 0x55 0x54 0x48 0x20`), and **constant-time-compares** the remainder against
the token. On match the client is admitted; the wire is then **byte-identical to
v0.2.0** — the server immediately writes the cached SPS/PPS, forces a fresh IDR
(`onClientConnected`), then fans out raw Annex-B. On mismatch / timeout / empty
token the socket is closed (fail-closed) and `rejectedTotal` increments. `\r` is
tolerated; the token itself contains no spaces.

**Token source (resolution order, extension side — `BroadcastConfig.load()`):**
1. **App Group** `mirror-config.json` → `authToken` — the per-device rotation
   path the host app writes (`SharedMirrorConfig.publishAuthTokenIfConfigured`).
   Requires `com.apple.security.application-groups` on host + extension and the
   group registered on ASC. **DORMANT** while `appGroupID == nil` (the default).
2. **Baked default** `BroadcastConfig.defaultAuthToken` — a farm shared secret
   compiled into the extension. This is what a fresh install rides, so auth is
   live with **zero App-Group signing complexity**. The bmfarm host presents the
   same value from its config (`FARM_IOS_REPLAYKIT_AUTH_TOKEN`, Phase-2 lane).

**Reversible kill-switch.** `wifiEnabled` (App-Group overridable, default true)
binds loopback-only when false — reverting to the exact pre-v0.3.0 USB-only
posture WITHOUT a rebuild.

**Phase-2 host wiring (bmfarm, routed separately).** Resolve the phone LAN IP,
try `<ip>:12005` with the token first and fall back to the USB `ios forward` on
failure (mirror the JB `bmtouchd` `FARM_JB_HOSTS` pattern); rotate a per-device
token via the App Group. **Producer note:** `MirrorServer.broadcast()` writes each
client with a blocking `send()`, so a stalled WiFi client can backpressure the
shared fan-out (incl. the USB client) — Phase-2 should isolate clients with
non-blocking sends + a bounded per-client queue.

## Downscale (the flagged production risk)

ReplayKit hands the extension a **full native-resolution** frame every time. On a
Pro/Max device (~1179×2556) a full-res encoder session risks the ReplayKit
~50 MB extension memory ceiling → a jetsam kill mid-broadcast. `DownscalePolicy`
caps the source's **long edge** at `maxLongEdge` (aspect-preserved, even
dimensions) and `PixelScaler` resizes via a hardware `VTPixelTransferSession` into
a small **pooled** buffer before encode, bounding the encoder working set.

Default cap **1920**: the current farm fleet (SE 750×1334, XR/11 828×1792) passes
through at its proven-safe native geometry; a Pro (1179×2556) is capped to
886×1920 (~1.7 Mpx) — inside the spike's measured-safe band (SE 1.0 Mpx ≈ 18 MB
RSS, no jetsam over ~130 s). **No Pro-class device exists in the current farm**, so
this is a conservative documented cap, not a measured-on-Pro one; lower `fps` /
`maxLongEdge` in `BroadcastConfig` (or a future App-Group `mirror-config.json`) if
any large device ever jetsams. `MemoryPressureGuard` additionally decimates the
encode rate under system memory pressure (warning → drop ~½, critical → drop ~¾)
so a spike degrades the frame rate instead of losing the session.

## Audio (`:12006`)

**Stubbed + flagged as a follow-up — video is the priority.** iOS ships **no
system Opus encoder** (AudioToolbox/AVFoundation don't expose Opus on-device), so
Opus would require vendoring `libopus` into the fork. The cheap alternative, if
audio is wanted later, is **AAC-LC via `AVAudioConverter`** (a system encoder)
carried over `:12006` with the same loopback-fan-out pattern as video. The
`SampleHandler` audio path is a clean no-op today; `BroadcastConfig.audioPort`
reserves 12006.

## Build, sign, install

```bash
source ~/.config/appstoreconnect/env
export DEV_CERT_SERIAL=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
export DEVICE_UDID=<phone udid>        # xctrace list devices
./build.sh                             # → BroadcastMirror.ipa (+ the .app)

# install (turn the DevTools app's VPN OFF first if present)
xcrun devicectl device install app --device <UDID> build/Build/Products/Release-iphoneos/BroadcastMirror.app
xcrun devicectl device process launch --device <UDID> net.busymate.mirror
# farm: ios_find_and_tap "Start Broadcast"  → mirror streams on :12005
```

**Signing gotcha:** provision via the ASC API (`ascprov.rb`) + manual-sign.
`xcodebuild -allowProvisioningUpdates` returns `Authentication failed` when
creating NEW App IDs against this key, even though the raw API authenticates fine.

## Tests

```bash
cd Core && swift test      # deviceless: DownscalePolicy / AnnexB / BitratePolicy / FramePacer
```

Live broadcast → `:12005` → decode is verified by the bmfarm integration lane.
