// agent:set-config validation shared by the codex and opencode drivers. Only
// advertised ids are accepted — a stale app pick must not smuggle arbitrary
// strings into the next turn. Kept in one place so the drivers can't drift on
// the gating rules (e.g. which model an effort pick is validated against).

export interface ConfigCaps {
  models: Array<{ id: string; efforts?: string[] }>;
  modes: Array<{ id: string }>;
  /** The driver's current effective model id (explicit selection, or the live
   *  model where the driver tracks one). Effort picks validate against it. */
  currentModelId?: string;
  currentEffortId?: string;
}

export type ConfigPick =
  | { key: "model"; id: string; clearEffort: boolean }
  | { key: "effort"; id: string }
  | { key: "mode"; id: string };

/** Validate one (key, value) pick against advertised capabilities.
 *  Null = rejected (unknown key or unadvertised id); callers emit no echo. */
export function resolveConfigPick(key: string, value: string, caps: ConfigCaps): ConfigPick | null {
  switch (key) {
    case "model": {
      const model = caps.models.find((m) => m.id === value);
      if (!model) return null;
      // A carried-over effort the new model doesn't support would fail the turn.
      const clearEffort =
        caps.currentEffortId !== undefined && !model.efforts?.includes(caps.currentEffortId);
      return { key: "model", id: value, clearEffort };
    }
    case "effort": {
      const model = caps.models.find((m) => m.id === caps.currentModelId);
      if (!model?.efforts?.includes(value)) return null;
      return { key: "effort", id: value };
    }
    case "mode":
      return caps.modes.some((m) => m.id === value) ? { key: "mode", id: value } : null;
    default:
      return null;
  }
}
