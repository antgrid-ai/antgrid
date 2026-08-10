#!/usr/bin/env bash
#
# Fail if the committed iOS device dylib does not export every symbol the
# resolved ghostty_vte bindings declare.
#
# WHY THIS EXISTS
#   app/.prebuilt/ios-arm64/libghostty-vt.dylib beats the release download
#   unconditionally and without any hash check, so bumping the fork ref updates the
#   bindings while leaving the binary alone. That pairing is silent everywhere it
#   would be cheap to notice: it compiles, it archives, and App Store validation
#   passes, because @Native resolution is lazy even in AOT. It surfaces only as
#   `ArgumentError: Couldn't resolve native function …` at the first call of each
#   absent function, on device, where nobody is attached to a debugger. Shipping
#   ghostty v0.1.3's 102 exports against v0.1.4's 106-symbol bindings is exactly
#   how that happened once.
#
# Requires a pub resolution (`flutter pub get` in app/) to locate the bindings; an
# unresolvable check is treated as a failure, not skipped, or the guard is useless
# precisely when it is needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DYLIB="${1:-$REPO_ROOT/app/.prebuilt/ios-arm64/libghostty-vt.dylib}"
PKG_CONFIG="$REPO_ROOT/app/.dart_tool/package_config.json"

die() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$DYLIB" ] || die "$DYLIB not found"
[ -f "$PKG_CONFIG" ] || die "no $PKG_CONFIG — run \`flutter pub get\` in app/ first"

# The trailing quote in the pattern matters: without it this also matches
# "ghostty_vte_flutter", which has no bindings file.
ROOT_URI="$(awk '/"name": "ghostty_vte"/{f=1} f&&/"rootUri"/{print; exit}' "$PKG_CONFIG" \
  | sed -E 's/.*"rootUri": "([^"]+)".*/\1/')"
[ -n "$ROOT_URI" ] || die "ghostty_vte not present in $PKG_CONFIG"
BINDINGS="${ROOT_URI#file://}/lib/ghostty_vte_bindings_generated.dart"
[ -f "$BINDINGS" ] || die "$BINDINGS not found"

MISSING="$(comm -23 \
  <(grep -oE "symbol: 'ghostty_[A-Za-z0-9_]+'" "$BINDINGS" | sed "s/symbol: '//;s/'//" | sort -u) \
  <(nm -gU "$DYLIB" | grep ' _ghostty_' | awk '{print substr($3,2)}' | sort -u))"

if [ -n "$MISSING" ]; then
  printf 'bindings: %s\ndylib:    %s\n\n' "$BINDINGS" "$DYLIB" >&2
  printf '%s\n' "$MISSING" >&2
  die "$(printf '%s symbol(s) declared by the bindings are not exported by the dylib.\nRegenerate it: bash scripts/build-ghostty-ios.sh' "$(printf '%s\n' "$MISSING" | wc -l | tr -d ' ')")"
fi

printf 'ABI ok: every symbol the bindings declare is exported by %s\n' "$(basename "$DYLIB")"
