import { expect, test } from "bun:test";
import { augmentAgentLaunch, buildCodexNotifyInjection } from "../src/agent-launch-augmenter";
import { computeCommandHookHash, hookStateKey, EVENT_LABELS } from "../src/codex-hook-fingerprint";

const HOOK_COMMAND = { binary: "/Applications/O'Brien/Antgrid App/antgrid-bridge", preargs: ["hook"] };

test("injects hook defs and a matching pre-seeded trusted_hash", () => {
  const args = buildCodexNotifyInjection(HOOK_COMMAND);
  const joined = args.join(" ");
  expect(joined).toContain("hooks.PermissionRequest=");
  expect(joined).toContain("hooks.Stop=");
  expect(joined).toContain("hooks.state=");
  const cmdMatch = joined.match(/hooks\.Stop=.*?command="((?:\\.|[^"\\])*)"/);
  expect(cmdMatch).not.toBeNull();
  const stopCmd = cmdMatch![1].replace(/\\(["\\])/g, "$1");
  const stopHash = computeCommandHookHash({ eventLabel: EVENT_LABELS.Stop, command: stopCmd, timeoutSec: 600 });
  expect(joined).toContain(stopHash);
  expect(joined).toContain(hookStateKey(EVENT_LABELS.Stop, 0, 0));
});

test("codex hook command defs contain no raw backslash", () => {
  const defs = buildCodexNotifyInjection(HOOK_COMMAND).filter((a) =>
    /^hooks\.(PermissionRequest|Stop|SessionStart)=/.test(a),
  );
  expect(defs.length).toBe(3);
  for (const def of defs) {
    expect(def.replace(/\\"/g, "")).not.toContain("\\");
  }
});

test("codex notify value contains bridge argv and no Node runtime", () => {
  const { args } = augmentAgentLaunch("codex", "/tmp/abdir", undefined, HOOK_COMMAND);
  const notifyArg = args.find((a) => a.startsWith("notify="));
  expect(notifyArg).toBeDefined();
  expect(notifyArg).not.toContain("\\");
  expect(notifyArg).toContain("antgrid-bridge");
  expect(notifyArg).not.toMatch(/\bnode(?:\.exe)?\b/i);
});

test("codex hooks.state keys are TOML literal strings", () => {
  const stateArg = buildCodexNotifyInjection(HOOK_COMMAND).find((a) => a.startsWith("hooks.state="));
  expect(stateArg).toBeDefined();
  const stopKey = hookStateKey(EVENT_LABELS.Stop, 0, 0);
  expect(stateArg).toContain(`'${stopKey}'={trusted_hash=`);
  expect(stateArg).not.toContain(`"${stopKey}"=`);
});
