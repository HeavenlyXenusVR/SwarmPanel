#!/usr/bin/env bash
# Packages a built SwarmPanelTV.app as a sideloadable .ipa and verifies the
# bundle has everything a sideloading tool (Sideloadly, AltStore, ...) and
# tvOS need, failing loudly if anything is missing.
#
#   scripts/package-tvos-ipa.sh <path/to/SwarmPanelTV.app> <output.ipa> [path/to/Assets.xcassets]
#
# With the optional asset catalog argument it also compiles the app icon and
# Top Shelf art into the bundle if the build didn't (see below).
#
# An .ipa is a zip with the app inside a top-level Payload/ folder -- the
# same layout for tvOS as for iOS. Used by build-tvos.yml (PR builds) and
# release-ios.yml (releases). macOS only (plutil, lipo).
set -euo pipefail

APP="${1:?usage: package-tvos-ipa.sh <SwarmPanelTV.app> <output.ipa> [Assets.xcassets]}"
OUT="${2:?usage: package-tvos-ipa.sh <SwarmPanelTV.app> <output.ipa> [Assets.xcassets]}"
XCASSETS="${3:-}"
PLIST="$APP/Info.plist"
fail=0

# Unsigned builds of this project (CODE_SIGNING_ALLOWED=NO) come out without
# a compiled asset catalog -- the iOS release works around the same thing by
# running actool itself. Do the same for tvOS: compile the brand assets
# (layered app icon + Top Shelf) into the bundle and merge the Info.plist
# keys actool reports (CFBundleIcons, TVTopShelfImage) into the app's own.
if [ -n "$XCASSETS" ] && [ ! -f "$APP/Assets.car" ]; then
  echo "Assets.car missing -- compiling $XCASSETS with actool"
  MIN_OS="$(plutil -extract MinimumOSVersion raw -o - "$PLIST" 2>/dev/null || echo 17.0)"
  PARTIAL="$(mktemp -t tvos-assets-partial).plist"
  xcrun actool \
    --output-format human-readable-text \
    --notices --warnings \
    --platform appletvos \
    --target-device tv \
    --minimum-deployment-target "$MIN_OS" \
    --app-icon "App Icon & Top Shelf Image" \
    --output-partial-info-plist "$PARTIAL" \
    --compress-pngs \
    --compile "$APP" \
    "$XCASSETS"
  echo "--- keys added by actool"
  plutil -p "$PARTIAL" || true
  /usr/libexec/PlistBuddy -c "Merge $PARTIAL" "$PLIST"
  rm -f "$PARTIAL"
fi

check() { # check <description> <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   $what"
  else
    echo "  MISSING $what"
    echo "::error::SwarmPanelTV.app: $what"
    fail=1
  fi
}
key() { plutil -extract "$1" raw -o - "$PLIST"; }

echo "Verifying $APP"
check "Info.plist present" test -f "$PLIST"
for k in CFBundleIdentifier CFBundleExecutable CFBundleName CFBundleDisplayName \
         CFBundleShortVersionString CFBundleVersion CFBundlePackageType MinimumOSVersion; do
  check "Info.plist $k" key "$k"
done
check "CFBundlePackageType is APPL" test "$(key CFBundlePackageType 2>/dev/null)" = "APPL"
check "built for tvOS (DTPlatformName appletvos)" test "$(key DTPlatformName 2>/dev/null)" = "appletvos"
check "device family is Apple TV (UIDeviceFamily 3)" test "$(key UIDeviceFamily.0 2>/dev/null)" = "3"
EXE="$(key CFBundleExecutable 2>/dev/null || true)"
check "executable $EXE present" test -n "$EXE" -a -f "$APP/$EXE"
check "executable is arm64" sh -c "lipo -archs '$APP/$EXE' | grep -q arm64"
check "compiled asset catalog (Assets.car)" test -f "$APP/Assets.car"
check "app icon registered (CFBundleIcons)" key CFBundleIcons.CFBundlePrimaryIcon
check "Top Shelf image registered (TVTopShelfImage)" key TVTopShelfImage

echo "--- Info.plist"
plutil -p "$PLIST"

if [ "$fail" -ne 0 ]; then
  echo "::error::SwarmPanelTV.app is missing required contents; not packaging."
  exit 1
fi

WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
# -y keeps any symlinks inside the bundle as symlinks; zip (unlike ditto)
# writes no AppleDouble ._* entries, which some installers choke on.
(cd "$WORK" && zip -qry "$OUT_ABS" Payload -x "*.DS_Store")
rm -rf "$WORK"

echo "--- $OUT_ABS"
unzip -l "$OUT_ABS" | sed -n '1,8p'
unzip -l "$OUT_ABS" | grep -q "Payload/SwarmPanelTV.app/Info.plist" || { echo "::error::ipa has no Payload/SwarmPanelTV.app/Info.plist"; exit 1; }
echo "IPA ready: $(du -h "$OUT_ABS" | cut -f1)"
