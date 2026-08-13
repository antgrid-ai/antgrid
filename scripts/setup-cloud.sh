#!/bin/bash
# Setup Script for Claude Code cloud sandboxes (Ubuntu 24.04).
#
# Paste this into the cloud environment's "Setup Script" field at claude.ai/code.
# It runs as root BEFORE Claude Code launches, and ONLY when no cached
# environment exists — afterwards the filesystem is snapshotted and later
# sessions skip this script entirely. Keep it under ~5 min so the cache builds.
#
# Two platform rules shape everything below:
#   - Nothing echoed here is ever read. The agent does not exist yet, later
#     sessions never run this, and setup stdout is not surfaced in the session
#     UI. Anything a future session needs must be WRITTEN TO A FILE, which the
#     snapshot preserves. That is what $NOTES is for.
#   - A non-zero exit makes the SESSION FAIL TO START, so nothing here may be
#     fatal. Hence no `set -e`: failures are recorded and the script continues.
#
# Per-session work does NOT belong here — the snapshot keeps only what is on
# disk, so a service started here is gone by the next session. Use a
# SessionStart hook for that.
#
# Baseline already present: Node 20-22, Bun, PostgreSQL 16, git.
# NOT baseline, provided here: Flutter, the Linux desktop toolchain, the
# headless-display stack, and a Bun meeting the relay's floor.
set -uo pipefail

# Pin to the toolchain floor documented in CLAUDE.md (Gradle/AGP minimums and
# the KGP 2.2.20 invariant assume this). Keep in lockstep with the
# FLUTTER_VERSION in .github/workflows/.
FLUTTER_VERSION="3.47.0"
FLUTTER_HOME="/opt/flutter"
BUN_MIN="1.3.14"   # CLAUDE.md relay floor: below this, APNs fails TLS/ALPN
NOTES="/opt/antgrid-setup-notes.txt"   # outside the repo, so the snapshot keeps it

: > "$NOTES"
note() { echo "- $*" >> "$NOTES"; }

# ---------------------------------------------------------------------------
# Linux desktop toolchain.
#
# `flutter run -d linux` needs all of these, and CMake reports exactly ONE
# missing dependency per configure — so discovering them in-session costs a
# build round trip each. Worse, a failed configure poisons app/build/linux (the
# same install-prefix trap CLAUDE.md documents for Windows), so recovery is
# `rm -rf app/build/linux`, not a re-run.
#
# xvfb/gnome-keyring/dbus-x11 are for DRIVING the app headlessly: with no
# unlocked keyring, flutter_secure_storage returns KeyringLocked, the signed-in
# check never resolves, and the app sits on AuthSplash forever. Reads as a hang
# and is not one.
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y --no-install-recommends \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-13-dev \
  libsecret-1-dev libwebkit2gtk-4.1-dev libcurl4-openssl-dev \
  xvfb gnome-keyring dbus-x11 \
  || note "apt toolchain install FAILED. 'flutter run -d linux' will fail one CMake dep at a time, and each failure poisons app/build/linux (rm -rf it before retrying). Re-run the apt-get line from this script by hand."

# ---------------------------------------------------------------------------
# Bun floor. The cloud image ships a 1.3.x below the relay's minimum and the
# failure mode is a silent APNs handshake rejection, not a version error.
# /usr/local/bin/bun already symlinks into ~/.bun, so upgrading in place is
# picked up with no re-linking.
# ---------------------------------------------------------------------------
bun_now="$(bun --version 2>/dev/null || echo 0)"
if [ "$(printf '%s\n%s\n' "$BUN_MIN" "$bun_now" | sort -V | head -1)" != "$BUN_MIN" ]; then
  if curl -fsSL https://bun.sh/install | bash -s "bun-v$BUN_MIN"; then
    ln -sf /root/.bun/bin/bun /usr/local/bin/bun
  else
    note "Bun upgrade to $BUN_MIN FAILED (image has $bun_now), below the relay's APNs floor — iOS push fails its TLS/ALPN handshake with no version error."
  fi
fi

# ---------------------------------------------------------------------------
# Flutter.
# ---------------------------------------------------------------------------
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  git clone --depth 1 -b "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME" \
    || note "Flutter clone FAILED — there is no SDK in this environment."
fi

# Make flutter/dart resolvable from the AGENT's shell. A setup-shell `export` and
# `.bashrc` do NOT reach the agent's non-interactive `bash -c`, and the cloud
# env-var UI field can't expand `$PATH` (stores it literally). /usr/local/bin is
# on the default PATH for every shell, and Flutter's launcher follows the symlink
# back to its real SDK root — the supported way to expose a /opt-installed SDK.
ln -sf "$FLUTTER_HOME/bin/flutter" /usr/local/bin/flutter
ln -sf "$FLUTTER_HOME/bin/dart"    /usr/local/bin/dart

# Setup runs as root, but the agent may run as a non-root user: let git operate
# on the root-owned SDK repo, and let the SDK write its bin/cache at runtime.
git config --system --add safe.directory "$FLUTTER_HOME"
chmod -R a+rwX "$FLUTTER_HOME"

flutter config --disable-analytics
flutter --version          # fetches the Dart SDK + tool snapshot into bin/cache
flutter precache --linux   # engine artifacts, so the first build doesn't fetch

# ---------------------------------------------------------------------------
# Warm the caches that actually survive: ~/.pub-cache and ~/.bun/install/cache.
# The repo tree is re-cloned per session, so node_modules/.dart_tool written
# here are discarded — the global caches are the whole benefit.
#
# Bun is a documented incompatibility with the Anthropic security proxy, and
# measurably left its cache empty here while pub's filled, so treat its failure
# as expected rather than exceptional.
# ---------------------------------------------------------------------------
bun install \
  || note "root 'bun install' FAILED (Bun is a documented security-proxy incompatibility). Run 'bun install' at the repo root before starting the bridge host, or it crash-loops on 'Cannot find package antgrid-wire'."
(cd app && flutter pub get) \
  || note "app 'flutter pub get' FAILED — run it in-session."
(cd packages/antgrid_relay_client && dart pub get) \
  || note "antgrid_relay_client 'dart pub get' FAILED — its 'dart test' gate will not run."

# Deliberately NOT started here: the snapshot keeps only what is on disk, so a
# running cluster does not survive into the next session.
note "Postgres 16 is installed but its cluster is NOT running. Before 'bun run --filter antgrid-web test': pg_ctlcluster 16 main start && npm run setup"

# NOTE: no `claude plugin install` here. At setup time the CLI has no
# marketplaces registered — extraKnownMarketplaces in .claude/settings.json is
# read when the AGENT starts, which is after this script — so every install
# resolves against an empty registry and fails. It also exits 0 on failure, so a
# `|| echo WARN` guard never fires. The dart MCP server the repo actually needs
# comes from .mcp.json + enabledMcpjsonServers, not from a plugin.

exit 0
