#!/usr/bin/env bash
# Dev-time wrapper used by the App's LocalAgentLauncher when running unbundled.
# Set ANTGRID_AGENT_BIN=<repo>/bridge/bin/antgrid-bridge-dev.sh before launching the app.
exec bun "$(dirname "$0")/../src/index.ts" "$@"
