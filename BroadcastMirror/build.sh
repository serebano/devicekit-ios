#!/usr/bin/env bash
# Build + manual-sign the Broadcast Mirror host app (embeds the upload extension)
# and package it as an installable .ipa. Reproducible from a clean checkout on a
# macOS farm host with Xcode + the ASC key.
#
# Prereqs (env, from ~/.config/appstoreconnect/env + your device):
#   APP_STORE_CONNECT_KEY_ID  APP_STORE_CONNECT_ISSUER_ID
#   DEV_CERT_SERIAL           (security find-identity -v -p codesigning | grep 'Apple Development')
#   DEVICE_UDID               (xctrace list devices)
#
# Usage:  ./build.sh            # provision + generate + build + package
#         SKIP_PROVISION=1 ./build.sh   # reuse an existing prov.env
#
# The xcodebuild step is wrapped in a HARD TIMEOUT (default 20 min) so a wedged
# device layer (see busymate-devtools #1623) can never hang the build forever.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

RUBY="${RUBY:-/opt/homebrew/opt/ruby/bin/ruby}"   # the ruby with the xcodeproj gem
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1200}"             # seconds
CONFIG="${CONFIGURATION:-Release}"
OUT="$HERE/build"
IPA="$HERE/BroadcastMirror.ipa"

# perl-based hard timeout (macOS ships no `timeout`).
bound() { local t="$1"; shift; perl -e '
  my $t=shift; my $pid=fork();
  if($pid==0){ exec @ARGV; exit 127 }
  local $SIG{ALRM}=sub{ kill "TERM",$pid; sleep 2; kill "KILL",$pid; exit 124 };
  alarm $t; waitpid($pid,0); exit($?>>8)' "$t" "$@"; }

if [ "${SKIP_PROVISION:-0}" != "1" ]; then
  echo "==> provisioning via ASC API"
  "$RUBY" -e 'exit' >/dev/null 2>&1 || RUBY=ruby
  ruby ascprov.rb
fi
[ -f prov.env ] && source prov.env || true

echo "==> generating BroadcastMirror.xcodeproj"
"$RUBY" project.rb

echo "==> building + signing (hard timeout ${BUILD_TIMEOUT}s)"
rm -rf "$OUT" "$IPA"
bound "$BUILD_TIMEOUT" xcodebuild \
  -project BroadcastMirror.xcodeproj \
  -target BroadcastMirror \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT" \
  CODE_SIGN_STYLE=Manual \
  IDEDeviceManagementInhibitDeviceDiscovery=YES \
  build

APP="$OUT/Build/Products/$CONFIG-iphoneos/BroadcastMirror.app"
[ -d "$APP" ] || { echo "ERROR: app not produced at $APP" >&2; exit 1; }
echo "==> app: $APP"
echo "    embedded extension:"; ls "$APP/PlugIns" 2>/dev/null || echo "    (none — check embed phase!)"

echo "==> packaging .ipa"
rm -rf "$OUT/Payload"; mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
( cd "$OUT" && zip -qr "$IPA" Payload )
echo "==> IPA: $IPA"
echo ""
echo "Install on a farm phone (VPN off first if the DevTools app is present):"
echo "  xcrun devicectl device install app --device <UDID> \"$APP\""
echo "  xcrun devicectl device process launch --device <UDID> net.busymate.mirror"
echo "  # farm: ios_find_and_tap \"Start Broadcast\"   → mirror streams on :12005"
