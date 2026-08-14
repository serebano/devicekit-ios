# Broadcast Mirror

A ReplayKit **broadcast upload extension** + a lean host app that stream a farm
phone's screen as native hardware **H.264** over a loopback TCP socket. This is the
production build of the proven spike (busymate-devtools #1659): far above the
~25 fps XCUITest-screenshot ceiling, at native ~60 fps delivery paced to a chosen
encode rate.

- **Host app** `net.busymate.mirror` — opens the system broadcast picker
  automatically so the farm can start the mirror hands-off.
- **Upload extension** `net.busymate.mirror.upload` — `RPBroadcastSampleHandler`
  → VideoToolbox H.264 (Baseline, Annex-B) → `127.0.0.1:12005`.

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
| Transport       | TCP, `127.0.0.1:12005`, one-way (server → client), `TCP_NODELAY` |
| Payload         | Raw **Annex-B** H.264 elementary stream (start code `00 00 00 01`) |
| Codec / profile | H.264 **Baseline**, no B-frames, realtime |
| Parameter sets  | SPS/PPS **in-band**, re-emitted **before every IDR** |
| Resolution      | Advertised by the SPS. Capped at `maxLongEdge` (default **1920**), aspect-preserved, even dimensions |
| Frame rate      | `fps` (default **30**), paced down from ReplayKit's ~60 |
| On connect      | Server sends cached SPS/PPS immediately, **then forces a fresh IDR** so a late client decodes at the next frame |
| Multi-client    | Multiple simultaneous readers supported; a dead socket is reaped on write failure |
| Audio           | `:12006` **reserved, not yet implemented** (see below) |

A client should: read the stream, split on start codes, feed SPS/PPS + the next
IDR to the decoder, then decode subsequent slices. Because config precedes every
IDR and an IDR is forced on connect, join latency is one keyframe (≤ ~1 frame).

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
