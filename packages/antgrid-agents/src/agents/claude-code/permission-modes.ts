// The SDK's fixed PermissionMode enum (setPermissionMode), NOT a discovered
// catalog — supportedAgents() lists subagent definitions, which are not modes.
// bypassPermissions is deliberately not offered remotely (it skips every
// permission check — unsafe over the wire). Shared by the chat backend and the
// registry so the scheduler's approval cap reads the same list the picker offers.
//
// `gated` is true when the mode still stops to ask before running tools. "auto"
// lets a classifier answer prompts and "acceptEdits" skips the edit prompts, so
// neither stops the run for the user.
export const PERMISSION_MODES = [
  { id: "default", name: "Default", description: "Ask before each tool use", gated: true },
  { id: "auto", name: "Auto", description: "Model classifier approves or denies tool prompts", gated: false },
  { id: "acceptEdits", name: "Accept edits", description: "Auto-approve file edits", gated: false },
  { id: "plan", name: "Plan", description: "Read-only planning mode", gated: true },
] as const;
