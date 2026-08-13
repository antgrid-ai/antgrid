export const CHECKOUT_KINDS = ["main", "managed-worktree", "external-worktree"] as const;
export type CheckoutKind = (typeof CHECKOUT_KINDS)[number];

export const CHECKOUT_STATES = ["ready", "missing", "failed"] as const;
export type CheckoutState = (typeof CHECKOUT_STATES)[number];

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
}
