#!/usr/bin/env bash
#
# Produce an App-Store-compliant libghostty-vt.dylib for iOS device (arm64).
#
# WHY THIS EXISTS
#   ghostty-vt is a Zig library. Zig's self-hosted Mach-O linker emits a dylib
#   that is NOT built by Apple's ld64, so it lacks LC_ENCRYPTION_INFO_64, is not
#   PIE, and isn't 16 KB segment-aligned. App Store validation rejects exactly
#   that binary (ITMS-90125 / ITMS-90209 / ITMS-90080). No post-processing tool
#   can inject LC_ENCRYPTION_INFO — it is an ld64 artifact. So we let Zig only
#   COMPILE (produce libghostty-vt.a), then do the FINAL LINK with Apple's
#   clang/ld64, which stamps all three. The result is a normal dynamic dylib the
#   ghostty_vte build hook bundles as-is (DynamicLoadingBundled), which is the
#   only link mode Flutter's iOS native-assets driver accepts.
#
# WHERE IT RUNS
#   macOS with Xcode <= 16 (e.g. the GitHub `macos-15` runner). Zig 0.15.2's
#   linker cannot link against the macOS 26 / Xcode 26 SDK, so this cannot run on
#   a macOS 26 host — build the artifact on macos-15 and commit the result.
#
# OUTPUT
#   app/.prebuilt/ios-arm64/libghostty-vt.dylib (force-tracked; the hook's
#   .prebuilt/ lookup finds it before the non-compliant upstream download).
#
# GHOSTTY_REF must match the ghostty submodule pinned by the ghostty_vte release
# whose bindings this repo vendors, or the C ABI can drift from
# ghostty_vte_bindings_generated.dart. debcffba == ghostty_vte-v0.1.3.
set -euo pipefail

GHOSTTY_REF="${GHOSTTY_REF:-debcffbadb75221a030319c075fae12cfe114176}"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
# 13.0 must equal Flutter's hardcoded native-asset framework MinimumOSVersion
# (targetIOSVersion in flutter_tools ios/native_assets.dart, flutter/flutter#145104).
# Flutter stamps ghostty-vt.framework/Info.plist with that constant regardless of the
# app's deployment target; if the dylib's minos exceeds it, the framework binary can't
# run on the OS its own Info.plist advertises → App Store ITMS-90208. A lower floor than
# the 15.5 app is fine (a framework may support more), and this matches every other
# bundled native asset (the hook builds portable_pty at the same targetVersion).
IOS_MIN="${IOS_MIN:-13.0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/app/.prebuilt/ios-arm64}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ── Zig 0.15.2 (the version ghostty debcffba requires) ──
ZARCH="$(uname -m)"; [ "$ZARCH" = "arm64" ] && ZARCH=aarch64
ZIG_DIR="$WORK/zig"
log "Installing Zig $ZIG_VERSION ($ZARCH-macos)"
curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$ZARCH-macos-$ZIG_VERSION.tar.xz" -o "$WORK/zig.tar.xz"
mkdir -p "$ZIG_DIR" && tar xf "$WORK/zig.tar.xz" -C "$ZIG_DIR" --strip-components=1
ZIG="$ZIG_DIR/zig"
"$ZIG" version

# ── ghostty source at the pinned ref ──
log "Cloning ghostty @ $GHOSTTY_REF"
git clone --filter=blob:none https://github.com/ghostty-org/ghostty "$WORK/ghostty"
git -C "$WORK/ghostty" checkout --quiet "$GHOSTTY_REF"
git -C "$WORK/ghostty" submodule update --init --recursive --depth 1

# ── Zig builds the static archive ──
# No global --sysroot: it would also apply to ghostty's NATIVE build-helper tools
# (uucode table generators run on the host) and break their host libc link. Zig
# auto-detects the macOS SDK for native tools and the iOS SDK for the aarch64-ios
# target via xcrun (this mirrors the ghostty_vte hook's own source-build call).
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
log "Building libghostty-vt.a for aarch64-ios (Zig compile only)"
# Run inside the ghostty checkout so Zig's .zig-cache lands in $WORK (cleaned by
# the trap), not the caller's CWD / repo root.
(
  cd "$WORK/ghostty"
  "$ZIG" build -Demit-lib-vt=true -Dtarget=aarch64-ios -Doptimize=ReleaseFast -Dsimd=false \
    --prefix "$WORK/prefix" --summary all
)

STATIC="$(find "$WORK/prefix" -name 'libghostty-vt.a' | head -1)"
[ -n "$STATIC" ] || { echo "libghostty-vt.a not produced" >&2; exit 1; }
log "Static archive: $STATIC"

# ── FINAL LINK with Apple clang/ld64 → compliant dynamic dylib ──
DYLIB="$WORK/libghostty-vt.dylib"
log "Relinking with clang/ld64 (arm64-apple-ios$IOS_MIN)"
xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min="$IOS_MIN" \
  -isysroot "$IOS_SDK" -install_name @rpath/libghostty-vt.dylib \
  -Wl,-all_load "$STATIC" -o "$DYLIB"

# ── Verify the three rejections are cured before publishing ──
log "Verifying App Store compliance"
otool -l "$DYLIB" | grep -q "LC_ENCRYPTION_INFO_64" \
  || { echo "FAIL: LC_ENCRYPTION_INFO_64 absent (ITMS-90125)" >&2; exit 1; }
# __LINKEDIT must start on a 16 KB boundary (ITMS-90209).
LE_OFF="$(otool -l "$DYLIB" | awk '/segname __LINKEDIT/{f=1} f&&/fileoff/{print $2; exit}')"
# Guard the regex explicitly: an empty LE_OFF (otool format drift, segment
# missing) is 0 in bash arithmetic and would pass the modulo check silently.
[[ "$LE_OFF" =~ ^[0-9]+$ ]] && [ $((LE_OFF % 16384)) -eq 0 ] \
  || { echo "FAIL: __LINKEDIT fileoff '$LE_OFF' missing or not 16 KB-aligned (ITMS-90209)" >&2; exit 1; }
otool -hv "$DYLIB" | grep -q "PIE" \
  || echo "WARN: PIE flag not reported (ITMS-90080 is a warning only)"
# minos must equal IOS_MIN: if it overshoots the MinimumOSVersion Flutter stamps into
# the wrapping framework's Info.plist, Apple rejects with ITMS-90208 (see IOS_MIN note).
MINOS="$(vtool -show-build "$DYLIB" | awk '/minos/{print $2; exit}')"
[ "$MINOS" = "$IOS_MIN" ] \
  || { echo "FAIL: dylib minos '$MINOS' != IOS_MIN '$IOS_MIN' (ITMS-90208 risk)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cp "$DYLIB" "$OUT_DIR/libghostty-vt.dylib"
log "Wrote $OUT_DIR/libghostty-vt.dylib"
otool -l "$OUT_DIR/libghostty-vt.dylib" | grep -A2 "LC_ENCRYPTION_INFO_64"
vtool -show-build "$OUT_DIR/libghostty-vt.dylib" | grep -E "platform|minos"
