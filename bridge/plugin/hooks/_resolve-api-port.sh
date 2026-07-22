# Shared helper: resolve the Antgrid agent API port for the notify hooks.
# SOURCE this (do not execute) — on success it sets $PORT to a validated
# numeric port; when there is no agent to notify it `exit 0`s the caller.
#
# Resolution order: ANTGRID_API_PORT (per-core, stamped into the terminal env by
# the bridge) wins; else the shared $ANTGRID_DIR/api.port file (best-effort
# single-core fallback — see api-server.ts).
ANTGRID_DIR="${ANTGRID_DIR:-$HOME/.antgrid}"
if [ -n "${ANTGRID_API_PORT:-}" ]; then
  PORT="$ANTGRID_API_PORT"
else
  PORT_FILE="$ANTGRID_DIR/api.port"
  [ -f "$PORT_FILE" ] || exit 0
  PORT=$(<"$PORT_FILE")   # builtin read — no `cat` subprocess
fi
# Numeric-validate: a stale/garbage value must not build a bogus curl URL.
case "$PORT" in
  ''|*[!0-9]*) exit 0 ;;
esac
