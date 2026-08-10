#!/usr/bin/env bash
#
# Produce the libghostty-vt.dylib for iOS device (arm64) that
# app/.prebuilt/ios-arm64/ carries, from the upstream ghostty_vte release.
#
# WHY THIS EXISTS
#   Upstream's published iOS device asset is linked by Apple's ld64 and is
#   App-Store-compliant as shipped — except for one field. Its minos is 17.0
#   (Zig's default for aarch64-ios), while Flutter's iOS native-assets driver
#   hardcodes every wrapped framework's Info.plist MinimumOSVersion to 13.0
#   (targetIOSVersion, flutter/flutter#145104) regardless of the app's deployment
#   target. A framework binary whose minos exceeds the version its own Info.plist
#   advertises is ITMS-90208, so this script restamps minos and changes nothing
#   else. There is no compile step and no source build.
#
#   It used to do much more. Through ghostty_vte-v0.1.3 the asset was linked by
#   Zig's OWN Mach-O linker (Mach-O build tool 5, no LC_ENCRYPTION_INFO_64,
#   old-style LC_DYLD_INFO_ONLY) and Apple additionally rejected it for
#   ITMS-90125/90209/90080; curing that required letting Zig only compile and
#   handing the final link to ld64, which meant installing Zig and running on a
#   macOS with Xcode <= 16. v0.1.4 switched upstream to ld64 (tool LD, chained
#   fixups, LC_ENCRYPTION_INFO_64 present) and made all of that unnecessary.
#   The pre-flight checks below assert that upstream has not regressed to the Zig
#   linker — if they fire, the relink approach is needed again and lives in git
#   history (see docs/ios-ghostty-vt-appstore-rejection.md).
#
# WHERE IT RUNS
#   Any macOS with the Xcode command line tools. No Zig, no pinned runner image.
#
# OUTPUT
#   app/.prebuilt/ios-arm64/libghostty-vt.dylib (force-tracked; the hook's
#   .prebuilt/ lookup finds it before the release download, unconditionally and
#   without consulting the lock's hashes).
set -euo pipefail

# The release the vendored ghostty_vte bindings belong to. Keep in lockstep with
# `releaseTag` in the fork's pkgs/vte/ghostty_vte/lib/src/hook/asset_hashes.dart:
# a dylib from an older ghostty exports fewer symbols than newer bindings declare,
# and because @Native resolution is lazy even in AOT that surfaces only as an
# ArgumentError at the first call of each absent function — on device, never on
# simulator. The symbol check at the end of this script is what catches it.
VTE_RELEASE_REPO="${VTE_RELEASE_REPO:-kingwill101/dart_terminal}"
VTE_RELEASE_TAG="${VTE_RELEASE_TAG:-ghostty_vte-v0.1.4}"
# The payload hash the fork's native_prebuilt.lock.yaml records for ios-arm64.
# Pinning it here ties the committed override to the same bytes the hook would
# have downloaded, so a silently re-cut upstream asset fails loudly.
EXPECTED_PAYLOAD_SHA256="${EXPECTED_PAYLOAD_SHA256:-71d259c95a320e914657dddd1f95ff2ad25057c8dc9f92f577073d495777ad3a}"
# Must equal Flutter's native-asset framework MinimumOSVersion (see the ITMS-90208
# note above). A framework may declare a lower floor than the app; the app's own
# deployment target is what actually bounds the install base.
IOS_MIN="${IOS_MIN:-13.0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/app/.prebuilt/ios-arm64}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# __LINKEDIT must start on a 16 KB boundary (ITMS-90209). Guard the regex
# explicitly: an empty offset (otool format drift, segment missing) is 0 in bash
# arithmetic and would pass the modulo check silently.
assert_compliant() {
  local dylib="$1" label="$2"
  otool -l "$dylib" | grep -q LC_ENCRYPTION_INFO_64 \
    || die "$label: LC_ENCRYPTION_INFO_64 absent (ITMS-90125) — upstream relinked with Zig?"
  local le
  le="$(otool -l "$dylib" | awk '/segname __LINKEDIT/{f=1} f&&/fileoff/{print $2; exit}')"
  [[ "$le" =~ ^[0-9]+$ ]] && [ $((le % 16384)) -eq 0 ] \
    || die "$label: __LINKEDIT fileoff '$le' missing or not 16 KB-aligned (ITMS-90209)"
  vtool -show-build "$dylib" | grep -qE '^ +tool +LD$' \
    || die "$label: not stamped by Apple's ld64 (ITMS-90125 risk) — upstream relinked with Zig?"
}

# ── Fetch the published device asset ──
URL="https://github.com/$VTE_RELEASE_REPO/releases/download/$VTE_RELEASE_TAG/vte-ios-arm64.tar.gz"
log "Downloading $URL"
curl -fsSL "$URL" -o "$WORK/vte-ios-arm64.tar.gz"
# Extract into a subdirectory: the tarball holds the dylib at its root, which
# would otherwise collide with the restamp output written beside it.
mkdir -p "$WORK/upstream"
tar xzf "$WORK/vte-ios-arm64.tar.gz" -C "$WORK/upstream"
UPSTREAM="$(find "$WORK/upstream" -name 'libghostty-vt.dylib' | head -1)"
[ -n "$UPSTREAM" ] || die "libghostty-vt.dylib not found in the tarball"

ACTUAL_SHA="$(shasum -a 256 "$UPSTREAM" | cut -d' ' -f1)"
[ "$ACTUAL_SHA" = "$EXPECTED_PAYLOAD_SHA256" ] \
  || die "payload sha256 $ACTUAL_SHA != expected $EXPECTED_PAYLOAD_SHA256 (asset re-cut, or wrong tag)"
log "Payload hash matches the fork lock's ios-arm64 entry"

# ── Assert upstream is still ld64-linked before trusting a restamp ──
log "Verifying the upstream asset is App-Store-compliant apart from minos"
assert_compliant "$UPSTREAM" upstream

# ── Restamp minos; preserve the platform's SDK and linker records ──
SDK="$(vtool -show-build "$UPSTREAM" | awk '/^ +sdk /{print $2; exit}')"
LD_VERSION="$(vtool -show-build "$UPSTREAM" | awk '/^ +version /{print $2; exit}')"
DYLIB="$WORK/libghostty-vt.dylib"
cp "$UPSTREAM" "$DYLIB"
log "Restamping minos -> $IOS_MIN (sdk $SDK, tool ld $LD_VERSION)"
vtool -set-build-version ios "$IOS_MIN" "$SDK" -tool ld "$LD_VERSION" -replace \
  -output "$DYLIB" "$DYLIB"

# ── Verify the result ──
log "Verifying the restamped dylib"
assert_compliant "$DYLIB" restamped
MINOS="$(vtool -show-build "$DYLIB" | awk '/minos/{print $2; exit}')"
[ "$MINOS" = "$IOS_MIN" ] || die "minos '$MINOS' != IOS_MIN '$IOS_MIN' (ITMS-90208)"
[ "$(otool -D "$DYLIB" | tail -1)" = "@rpath/libghostty-vt.dylib" ] \
  || die "unexpected install name $(otool -D "$DYLIB" | tail -1)"
# The restamp must not perturb anything else in the file.
UP_SYMS="$(nm -gU "$UPSTREAM" | grep -c ' _ghostty_')"
NEW_SYMS="$(nm -gU "$DYLIB" | grep -c ' _ghostty_')"
[ "$UP_SYMS" = "$NEW_SYMS" ] || die "export count changed across the restamp ($UP_SYMS -> $NEW_SYMS)"
log "$NEW_SYMS exported ghostty_ symbols"

# ── The check that would have caught the v0.1.3/v0.1.4 ABI drift ──
# Verify BEFORE installing, so a mismatched artifact never lands in .prebuilt/.
log "Checking the ABI against the resolved bindings"
bash "$REPO_ROOT/scripts/check-ghostty-ios-abi.sh" "$DYLIB"

mkdir -p "$OUT_DIR"
cp "$DYLIB" "$OUT_DIR/libghostty-vt.dylib"
log "Wrote $OUT_DIR/libghostty-vt.dylib"
shasum -a 256 "$OUT_DIR/libghostty-vt.dylib"
vtool -show-build "$OUT_DIR/libghostty-vt.dylib" | grep -E 'platform|minos|sdk|tool|version'
