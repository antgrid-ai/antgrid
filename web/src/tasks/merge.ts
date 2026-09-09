/**
 * Three-way merge of one task against its shadow snapshot.
 *
 * Pure by design — no database, no provider client, no clock. Every caller
 * (webhook processor and outbox drain alike) has to hold
 * `pg_advisory_xact_lock(hashtext('tasksync:' || taskId))` across its
 * read-merge-write, because two consumers doing that on one row is how a task's
 * own in-flight push comes back as a conflict against itself. Keeping this
 * function pure is what lets that lock live entirely in the callers.
 *
 * The asymmetry in the types below is deliberate and load-bearing: `local` is
 * Antgrid vocabulary, while the snapshot and the provider payload are provider
 * space. `status` maps many-to-one onto GitHub, so comparing Antgrid values
 * against a provider snapshot is a self-sustaining push loop.
 */

export type TaskStatus = "open" | "in_progress" | "blocked" | "done" | "cancelled";

export type RemoteStateReason = "completed" | "not_planned" | "reopened" | null;

/** The raw provider projection of status — what a snapshot stores verbatim. */
export interface RemoteState {
  state: "open" | "closed";
  stateReason?: RemoteStateReason;
}

export type Assignee =
  | { kind: "member"; userId: string }
  | { kind: "external"; externalId: string; login: string; avatarUrl?: string | null };

/** The local row, in Antgrid vocabulary. */
export interface LocalFields {
  title: string;
  body: string;
  status: TaskStatus;
  labels: string[];
  assignee: Assignee | null;
}

/** `Task.remoteSnapshot`: the last state both sides agreed on. Provider space. */
export interface SnapshotFields {
  title: string;
  body: string;
  status: RemoteState;
  labels: string[];
  assignee: Assignee | null;
  /**
   * Every assignee the provider held, carried for display only — the "+n others
   * on GitHub" marker. GitHub allows ten assignees and the local column pair
   * keeps one, so this is the only record that the other nine existed.
   *
   * Deliberately NOT merged: `mergeTask` walks a named field list, and this is
   * absent from it. Optional because snapshots written before it existed must
   * keep parsing, and an absent array means "unknown", not "nobody else".
   */
  assignees?: Assignee[];
}

/** The provider payload as it arrived. Provider space, like the snapshot. */
export type RemoteFields = SnapshotFields;

export type ScalarField = "title" | "body" | "status" | "assignee";

export interface MergeConflict {
  field: ScalarField;
  /** The local value that lost. Persisted to `Task.localConflict` — never dropped. */
  localValue: unknown;
  remoteValue: unknown;
}

export interface MergeResult {
  /** Field values to write to the local row. Antgrid vocabulary. */
  apply: Partial<LocalFields>;
  /** Fields whose local value is ahead of the remote and should be pushed. */
  push: ScalarField[];
  /** Non-empty means `syncState='conflict'` plus the UI marker. */
  conflicts: MergeConflict[];
  /** The merged label set, when it differs from the local row. */
  labelsChanged: boolean;
  /** The merged set differs from the remote's, so it needs an `issue.labels`
   *  op. A separate question from `labelsChanged`: a label added locally is
   *  already on the local row (nothing to apply) and still has to be pushed. */
  labelsPush: boolean;
  /** Labels dropped while the other side still had them. Remove-always-wins is
   *  correct but data-loss-shaped, so these get a UI marker even though the
   *  field never enters `conflict` state. */
  labelRemoveWins: string[];
}

const STATUS_TO_REMOTE: Record<TaskStatus, RemoteState> = {
  open: { state: "open" },
  in_progress: { state: "open" },
  blocked: { state: "open" },
  done: { state: "closed", stateReason: "completed" },
  cancelled: { state: "closed", stateReason: "not_planned" },
};

export function toRemote(status: TaskStatus): RemoteState {
  return STATUS_TO_REMOTE[status];
}

/**
 * Provider status → ours, with the sub-status hint taken from the LOCAL row
 * rather than the snapshot. The snapshot is provider space and has no
 * sub-status left in it to preserve, and `open` coming back is ambiguous
 * between "unchanged" and "reopened" — so without this an inbound event for an
 * untouched open issue clobbers a live `in_progress` back to `open`.
 */
export function fromRemote(remote: RemoteState, local: TaskStatus): TaskStatus {
  if (remote.state === "closed") {
    return remote.stateReason === "not_planned" ? "cancelled" : "done";
  }
  return local === "in_progress" || local === "blocked" ? local : "open";
}

/**
 * `state_reason` is meaningless while an issue is open — GitHub stamps
 * `reopened` there and we never send one — so comparing it on an open issue
 * manufactures a diff on every reconcile and resurrects the push loop that
 * provider-space merging exists to kill.
 */
export function sameRemoteState(a: RemoteState, b: RemoteState): boolean {
  if (a.state !== b.state) return false;
  if (a.state === "open") return true;
  return (a.stateReason ?? null) === (b.stateReason ?? null);
}

/** Assignee identity, in one place: a member is its `userId` and an external is
 *  its `externalId`. Exported because the API's "+n others" marker has to strip
 *  the chosen assignee out of the snapshot array by the same rule the merge
 *  compares by, and two spellings of it would drift. */
export function sameAssignee(a: Assignee | null, b: Assignee | null): boolean {
  if (a === null || b === null) return a === b;
  if (a.kind !== b.kind) return false;
  if (a.kind === "member" && b.kind === "member") return a.userId === b.userId;
  if (a.kind === "external" && b.kind === "external") return a.externalId === b.externalId;
  return false;
}

export function mergeTask(args: {
  base: SnapshotFields;
  local: LocalFields;
  remote: RemoteFields;
}): MergeResult {
  const { base, local, remote } = args;

  const apply: Partial<LocalFields> = {};
  const push: ScalarField[] = [];
  const conflicts: MergeConflict[] = [];

  mergeScalar({
    field: "title",
    base: base.title,
    local: local.title,
    remote: remote.title,
    equal: (x, y) => x === y,
    onApply: (value) => { apply.title = value; },
    push,
    conflicts,
  });

  mergeScalar({
    field: "body",
    base: base.body,
    local: local.body,
    remote: remote.body,
    equal: (x, y) => x === y,
    onApply: (value) => { apply.body = value; },
    push,
    conflicts,
  });

  // Compared entirely in provider space: `toRemote` is many-to-one, so an
  // `in_progress` local against an `open` snapshot must read as "no change".
  mergeScalar({
    field: "status",
    base: base.status,
    local: toRemote(local.status),
    remote: remote.status,
    equal: sameRemoteState,
    onApply: () => { apply.status = fromRemote(remote.status, local.status); },
    push,
    conflicts,
  });

  mergeScalar({
    field: "assignee",
    base: base.assignee,
    local: local.assignee,
    remote: remote.assignee,
    equal: sameAssignee,
    onApply: (value) => { apply.assignee = value; },
    push,
    conflicts,
  });

  const labels = mergeLabels(base.labels, local.labels, remote.labels);
  if (labels.changed) apply.labels = labels.next;

  return {
    apply,
    push,
    conflicts,
    labelsChanged: labels.changed,
    labelsPush: labels.push,
    labelRemoveWins: labels.removeWins,
  };
}

function mergeScalar<T>(args: {
  field: ScalarField;
  base: T;
  local: T;
  remote: T;
  equal: (a: T, b: T) => boolean;
  onApply: (remote: T) => void;
  push: ScalarField[];
  conflicts: MergeConflict[];
}): void {
  const { field, base, local, remote, equal } = args;
  const localMoved = !equal(local, base);
  const remoteMoved = !equal(remote, base);

  if (!localMoved && !remoteMoved) return;
  if (localMoved && !remoteMoved) {
    args.push.push(field);
    return;
  }
  if (!localMoved && remoteMoved) {
    args.onApply(remote);
    return;
  }
  // Both moved. Remote wins for these provider-owned fields, but the local
  // value is handed back for `Task.localConflict` — silent loss is the one
  // outcome that is never acceptable.
  args.onApply(remote);
  args.conflicts.push({ field, localValue: local, remoteValue: remote });
}

/**
 * Labels are a set and merge element-wise. A whole-value compare is wrong in
 * the expensive direction: two sides that each added a different label are not
 * in conflict, but a scalar compare calls it one and drops the loser's add.
 *
 * The formula is remove-always-wins — including when local removed an element
 * the remote added. That is one algorithm, not "remote wins for the same
 * element"; the two readings disagree on exactly the case that matters.
 */
function mergeLabels(
  base: string[],
  local: string[],
  remote: string[],
): { next: string[]; changed: boolean; push: boolean; removeWins: string[] } {
  const baseSet = new Set(base);
  const localSet = new Set(local);
  const remoteSet = new Set(remote);

  const added = new Set<string>();
  const removed = new Set<string>();
  for (const label of localSet) if (!baseSet.has(label)) added.add(label);
  for (const label of remoteSet) if (!baseSet.has(label)) added.add(label);
  for (const label of baseSet) {
    if (!localSet.has(label) || !remoteSet.has(label)) removed.add(label);
  }

  const next = new Set(baseSet);
  for (const label of added) next.add(label);
  for (const label of removed) next.delete(label);

  // A drop the OTHER side still had. `added ∩ removed` is empty by
  // construction — an element cannot be both absent from the base (to be added)
  // and present in it (to be removed) — so the marker has to be derived from
  // what each side still holds, not from the two diff sets.
  const removeWins = [...removed].filter((l) => localSet.has(l) || remoteSet.has(l));

  const sorted = [...next].sort();
  return {
    next: sorted,
    changed: !sameSet(next, localSet),
    push: !sameSet(next, remoteSet),
    removeWins: removeWins.sort(),
  };
}

function sameSet(a: Set<string>, b: Set<string>): boolean {
  if (a.size !== b.size) return false;
  for (const value of a) if (!b.has(value)) return false;
  return true;
}
