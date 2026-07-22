#!/usr/bin/env bash
# Fails if any raw `fontSize:` numeric literal appears in app/lib/**, with the
# sole exception of `app/lib/design/ab_tokens.dart` where the scale
# constants are defined. All other call sites must use AbTokens.fontXxx.
#
# Run from repo root: bash app/scripts/check_font_tokens.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# grep -E: 'fontSize:\s*[0-9]'   matches `fontSize: 12`, `fontSize: 11.5`, etc.
# --exclude:                     allow the token-definition file itself.
hits=$(grep -rnE 'fontSize:\s*[0-9]' lib \
  --include='*.dart' \
  --exclude='ab_tokens.dart' || true)

if [ -n "$hits" ]; then
  echo "ERROR: raw fontSize literals are not allowed in app/lib/**." >&2
  echo "Use a AbTokens.fontXxx constant instead. Offenders:" >&2
  echo "$hits" >&2
  exit 1
fi

echo "OK: no raw fontSize literals in app/lib/."
