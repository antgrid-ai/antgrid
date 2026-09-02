export const CHECKOUT_KINDS = ["main", "managed-worktree", "external-worktree"] as const;
export type CheckoutKind = (typeof CHECKOUT_KINDS)[number];

export const CHECKOUT_STATES = ["ready", "missing", "failed"] as const;
export type CheckoutState = (typeof CHECKOUT_STATES)[number];

/** How far `worktree.setup` has got for a managed checkout. Deliberately a
 *  separate vocabulary from CHECKOUT_STATES: that one answers "is this
 *  workspace usable" and stays `ready` throughout a setup run, while this
 *  answers "has provisioning finished". `interrupted` is what a checkout with a
 *  durable marker missing and no live runner reports after a bridge restart. */
export const SETUP_STATES = ["running", "done", "failed", "skipped", "interrupted"] as const;
export type SetupState = (typeof SETUP_STATES)[number];

/** The subset that may be written to checkouts.json. `running` is absent by
 *  design — a bridge that dies mid-setup would otherwise leave a row that is
 *  permanently preparing, with nothing alive to ever clear it. */
export const DURABLE_SETUP_STATES = ["done", "failed", "skipped"] as const;
export type DurableSetupState = (typeof DURABLE_SETUP_STATES)[number];

/** A coarse transition reported by the setup runner: step boundaries and
 *  terminal states only. Live output never travels this way — it rides the
 *  setup terminal's own `terminal:output`, which already has batching,
 *  scrollback and focus gating. `startedAt` / `finishedAt` / `pendingStart` on
 *  the wire entry are the session manager's to stamp, not the runner's. */
export interface CheckoutSetupProgress {
  state: SetupState;
  /** 0-based, the current step while running and the last one afterwards. */
  stepIndex: number;
  stepCount: number;
  stepName?: string;
  /** Every step's name, in plan order. Carried on every report of a run rather
   *  than once, so a reader that missed the first one is not left with a ledger
   *  it can only render as blanks. Absent for a checkout with no block at all. */
  stepNames?: string[];
  terminalId?: string;
  exitCode?: number;
  /** One-line failure summary. */
  message?: string;
}

/** Antgrid created this checkout's directory and is the only thing that may
 *  remove it — so a session that owns one must reclaim it on delete. */
export function isManagedCheckoutKind(kind: CheckoutKind): boolean {
  return kind === "managed-worktree";
}

/** This session's workspace is not the project's primary working tree, so every
 *  checkout-variable message must route to it and an app without the
 *  `checkoutRouting` capability must be refused the project. Deliberately NOT
 *  the same question as ownership: `main` is neither, and an external worktree
 *  would be isolated without ever being ours to delete. */
export function isIsolatedCheckoutKind(kind: CheckoutKind): boolean {
  return kind !== "main";
}

/** Host-local checkout metadata. Its path must never cross the session wire. */
export interface CheckoutRecord {
  id: string;
  projectId: string;
  kind: CheckoutKind;
  path: string;
  branch: string | null;
  /** The local branch the user explicitly picked as the base, or null when the
   *  main checkout's HEAD was used. Retained for provenance and support triage
   *  only — deliberately WRITE-ONLY, and deliberately a ref name rather than the
   *  base commit: a branch moves and can be deleted, so a reader asking "has the
   *  base moved since?" must put that question to Git (merge-base against the
   *  session branch), never trust this string. */
  baseRef: string | null;
  managed: boolean;
  sessionId: string | null;
  createdAt: number;
  /** How `worktree.setup` last ENDED for this checkout, absent until it has.
   *  A managed checkout with no marker and no live runner is `interrupted`, not
   *  `running`: the enum has no running member on purpose, so a bridge killed
   *  mid-setup can never leave a row that is permanently preparing. */
  setupState?: DurableSetupState;
  setupFinishedAt?: number;
  setupExitCode?: number;
}
