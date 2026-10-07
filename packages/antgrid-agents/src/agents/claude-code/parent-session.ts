// What a running Claude Code session stamps on every process it starts, so a
// bridge launched from inside one hands them to each agent it spawns. The
// inheriting Claude then believes it is that session's child: it turns
// transcript saving off (which blinds interrupt confirmation and resume) and
// may reach for the parent's messaging socket. Named one by one rather than as
// a `CLAUDE*` prefix, because users set CLAUDE_CODE_USE_BEDROCK,
// CLAUDE_CONFIG_DIR and similar on purpose and those must survive.
const PARENT_SESSION_VARS = [
  "CLAUDECODE",
  "CLAUDE_PID",
  "CLAUDE_EFFORT",
  "CLAUDE_CODE_CHILD_SESSION",
  "CLAUDE_CODE_SESSION_ID",
  "CLAUDE_CODE_SESSION_ATTENDED",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_EXECPATH",
  "CLAUDE_CODE_MESSAGING_SOCKET",
  "CLAUDE_CODE_MESSAGING_TOKEN",
] as const;

export function stripParentClaudeSession<T extends Record<string, string | undefined>>(env: T): T {
  const out = { ...env };
  for (const k of PARENT_SESSION_VARS) delete out[k];
  return out;
}
