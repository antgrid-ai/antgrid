export const CHECKOUT_KINDS = ["main", "managed-worktree", "external-worktree"] as const;
export type CheckoutKind = (typeof CHECKOUT_KINDS)[number];

export const CHECKOUT_STATES = ["ready", "missing", "failed"] as const;
export type CheckoutState = (typeof CHECKOUT_STATES)[number];

/** Host-local checkout metadata. Its path must never cross the session wire. */
export interface CheckoutRecord {
  id: string;
  projectId: string;
  kind: CheckoutKind;
  path: string;
  branch: string | null;
  baseRef: string | null;
  managed: boolean;
  sessionId: string | null;
  createdAt: number;
}
