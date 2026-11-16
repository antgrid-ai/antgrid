// Compiled by smoke-pty-lib-binary.ts: the first PTY spawn, which is the only
// thing that loads bun-pty's native library. A pid proves the library loaded:
// bun-pty swallows a failed dlopen, and its spawn then throws. The child's exit
// is not awaited, because bun-pty's read loop holds no handle open and a bare
// script can end before it reports (observed on Linux under WSL).
import { loadBunPty } from "../src/pty-native-lib";

const shell = process.platform === "win32" ? "cmd.exe" : "/bin/sh";
const pty = loadBunPty().spawn(shell, [], {
  name: "xterm-256color",
  cols: 80,
  rows: 24,
  cwd: process.cwd(),
  env: process.env as Record<string, string>,
});
if (!(pty.pid > 0)) throw new Error(`pty spawn returned pid ${pty.pid}`);
pty.kill();
console.log("pty-ok");
console.log(`BUN_PTY_LIB=${process.env.BUN_PTY_LIB ?? "<unset>"}`);
process.exit(0);
