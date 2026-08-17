# Broadcast Mirror — Changelog

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
