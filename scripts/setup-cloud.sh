#!/bin/bash
# Setup Script for Claude Code cloud sandboxes (Ubuntu 24.04).
#
# Paste this into the cloud environment's "Setup Script" field. It runs as root
# before the agent starts, and its output is cached across sessions, so Flutter
# installs once per environment, not per run. Keep it under ~5 min to cache.
#
# Baseline already present in cloud: Node 20-22, Bun, PostgreSQL 16, git.
# Flutter is NOT baseline — this script provides it.
set -euo pipefail

# Pin to the toolchain floor documented in CLAUDE.md (Gradle/AGP minimums and the
# KGP 2.2.20 invariant assume this). Bump in lockstep with the repo's Flutter pin.
FLUTTER_VERSION="3.44.2"
FLUTTER_HOME="/opt/flutter"

if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  git clone --depth 1 -b "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME"
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

flutter config --no-analytics
flutter --version   # fetches the Dart SDK + tool snapshot into bin/cache (cached)

# Install plugins explicitly. Cloud does NOT reliably auto-install from the
# committed .claude/settings.json (which declares the marketplace + enabledPlugins),
# so use the CLI — proven to work. Best-effort: a hiccup shouldn't fail setup.
# NOTE: this installs at the user scope of whoever runs setup (root). If the agent
# runs as a different user and doesn't see the plugins, install in-session instead.
claude plugin install superpowers@claude-plugins-official     || echo "WARN: superpowers install failed; run in-session"
claude plugin install code-simplifier@claude-plugins-official || echo "WARN: code-simplifier install failed; run in-session"

# Warm the workspace caches so the first `flutter test` / `bun test` is fast.
# Best-effort: a cold network here shouldn't fail the whole setup.
bun install || echo "WARN: root bun install failed; run it in-session"
(cd app && flutter pub get) || echo "WARN: flutter pub get failed; run it in-session"
