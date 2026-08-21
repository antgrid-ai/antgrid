# Dev-time agent wrappers

Used by the App's `LocalAgentLauncher` when running unbundled (no
`antgrid` on PATH, no bundled `antgrid-bridge` next to the Flutter executable).

Set `ANTGRID_AGENT_BIN` to the absolute path of the wrapper for your platform
before launching the App from your IDE / `flutter run`:

```bash
# macOS / Linux
export ANTGRID_AGENT_BIN="$(pwd)/bridge/bin/antgrid-bridge-dev.sh"
chmod +x "$ANTGRID_AGENT_BIN"   # one-time

# Windows (PowerShell)
$env:ANTGRID_AGENT_BIN = "$(Get-Location)\agent\bin\antgrid-bridge-dev.cmd"
```

Each wrapper just `exec`s `bun src/index.ts` with the same args, so launching
`antgrid serve --local --folder <path>` works identically to a built binary.
