# Broadcast Mirror — Changelog

## broadcast-mirror-v0.3.1 (busymate-devtools #1763, Phase 2 of #1759)

**Non-blocking fan-out hardening — a slow WiFi client can no longer degrade the
concurrent USB mirror.** v0.3.0's `MirrorServer.broadcast()` wrote each frame to
every client with a BLOCKING `send()` on the SHARED fan-out path, so a slow/stalled
WiFi client backpressured EVERY client — including the USB (loopback) stream the
farm relies on for control + charging. That is a real regression risk once WiFi is
a live transport, so v0.3.1 makes the fan-out non-blocking + per-client bounded:

- **Per-client outbound queue + dedicated writer thread.** `broadcast()` now only
  ENQUEUEs each frame (O(1), never blocks); a per-client `MirrorClient` writer
  thread drains its OWN queue with a send-TIMEOUT-bounded `send()`, so one client's
  back-pressure is contained to its own thread + queue — it can never stall
  `broadcast()` or another client.
- **Bounded queue, shed-oldest.** A client's queue is capped at `maxClientQueueBytes`
  (default 4 MB, App-Group tunable); when it overflows the OLDEST *data* frames are
  dropped (the client keeps the freshest frames + re-syncs at the next IDR). SPS/PPS
  config frames are marked and NEVER shed.
- **Stalled-client eviction.** Each client socket carries `SO_SNDTIMEO` (default
  250 ms); `maxSendStalls` (default 8) consecutive zero-progress send timeouts ⇒ the
  client is stalled → DROPPED (its writer exits, the server reaps it). A dropped
  WiFi client frees its slot without touching the USB stream.
- The admit-path config prime is now ENQUEUED (not a blocking write), so a new
  client never stalls the fan-out either. SIGPIPE stays ignored; the writer thread
  is the SOLE owner of its fd close (a server-side `stop()`/reap does `shutdown()`
  to unblock a stalled send).
- No change to the encode pipeline, the auth handshake, or the `:12005` Annex-B wire
  contract — the wire is byte-identical to v0.3.0.

## broadcast-mirror-v0.3.0 (busymate-devtools #1759, umbrella #1739)

WiFi transport enabler for the ReplayKit H.264 `:12005` mirror — usbmux-dark
resilience (a USB brownout no longer blinds the mirror; WiFi is a disjoint link).

- **Bind `0.0.0.0:12005`** instead of loopback-only. Binding all interfaces KEEPS
  loopback working, so the existing USB `ios forward … 12005` path is byte-for-byte
  unaffected; a WiFi client can now reach `<phone_lan_ip>:12005`.
- **Shared-token auth gate on every non-loopback connection.** A WiFi/LAN client
  must send `AUTH <token>\n` (≤512 B, `\n`-terminated, 3 s timeout) before any
  frames; the server constant-time-compares it, then the wire is byte-identical to
  v0.2.0 (cached SPS/PPS → forced IDR → Annex-B fan-out). Loopback (USB) is
  token-EXEMPT — only on-device code can reach `127.0.0.1`. The handshake runs on a
  per-client thread so a slow/silent scanner can never stall `accept()`.
- **Token source:** App Group `mirror-config.json` → `authToken` (per-device
  rotation, host app writes it — dormant until an App Group is provisioned) →
  baked `BroadcastConfig.defaultAuthToken` (farm shared secret, so auth is live
  with zero App-Group signing complexity). Full protocol + Phase-2 wiring in the
  README "WiFi transport + auth" section.
- **Reversible:** `wifiEnabled` (App-Group overridable, default true) binds
  loopback-only when false — the exact pre-v0.3.0 USB-only posture, no rebuild.
- `LoopbackServer` → `MirrorServer` (the "loopback" name was now a misnomer).
- No change to the H.264 encode pipeline, downscale, memory guard, or the `:12005`
  Annex-B wire contract after auth.

## broadcast-mirror-v0.2.0 (busymate-devtools #1659)

Production ReplayKit H.264 `:12005` mirror: host app + upload extension,
VideoToolbox Baseline Annex-B, 60 fps native off the display framebuffer, SPS/PPS
in-band + forced IDR on connect, downscale cap + memory-pressure guard,
device-independent unsigned build + per-device re-sign (Xcode-26 recipe).

## broadcast-mirror-v0.1.0

Initial spike.
