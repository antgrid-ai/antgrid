import { delimiter, join } from "node:path";
import { homedir } from "node:os";

// Dirs where CLI agents install but a macOS/Linux GUI-launched process won't see
// on PATH: a Finder/Dock (or systemd user-session) launch gives the app a
// minimal PATH (/usr/bin:/bin:…), missing the shell-profile additions where
// `claude`, `codex`, etc. actually live. The host inherits that stripped PATH,
// so every consumer that reads process.env.PATH — Bun.which resolution, the PTY,
// the SDK subprocess, tool detection, version/update probes — silently fails to
// find installed agents. win32 has no equivalent gap (installers write PATH
// machine-wide), so this stays POSIX-only.
export function wellKnownBinDirs(): string[] {
  if (process.platform === "win32") return [];
  const home = homedir();
  return [
    join(home, ".local/bin"),        // native installer default (claude 2.1+)
    join(home, ".claude/local"),     // legacy claude local install
    join(home, ".bun/bin"),
    "/opt/homebrew/bin",             // Apple-silicon Homebrew
    "/usr/local/bin",                // Intel Homebrew / manual installs
  ];
}

// Append the well-known bin dirs (that aren't already present) to a PATH string.
// Appended, not prepended, so a user-configured PATH still wins on name
// collisions. Dirs are added unconditionally — no launch-time existsSync gate:
// a missing dir on PATH is harmless (resolvers skip it) and, unlike a one-shot
// existence check, still resolves a binary that lands there later in the run
// (e.g. a self-update that first creates ~/.local/bin). Idempotent.
export function augmentPath(path: string | undefined): string {
  const existing = (path ?? "").split(delimiter).filter(Boolean);
  const have = new Set(existing);
  const extra = wellKnownBinDirs().filter((d) => !have.has(d));
  return [...existing, ...extra].join(delimiter);
}

// Mutate this host process's own PATH so every downstream consumer (Bun.which,
// PTY spawns, the Claude/Codex SDK subprocesses, tool detection) can locate
// agents installed in profile-only dirs. Call once, before anything resolves a
// binary (tool-detector memoizes its first probe). Genuine no-op on Windows —
// returns before touching PATH, so a stripped/trailing PATH segment is left
// byte-for-byte intact.
export function augmentHostPath(): void {
  if (wellKnownBinDirs().length === 0) return; // win32: nothing to add
  process.env.PATH = augmentPath(process.env.PATH);
}
