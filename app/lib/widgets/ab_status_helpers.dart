import '../connection/supervisor_state.dart';
import '../design/ab_status_tone.dart';
import '../models/terminal_models.dart';

/// Maps [SupervisorStatus] to a (tone, label) pair for status surfaces —
/// the ladder itself, not the raw socket phase, since only the ladder knows
/// whether the agent is actually on the other end.
(AbStatusTone, String) connectionDisplayInfo(SupervisorStatus status) {
  return switch (status) {
    Connected() => (AbStatusTone.success, 'Connected'),
    Climbing(:final rung) => (AbStatusTone.warning, _rungLabel(rung)),
    Blocked(:final reason) => (AbStatusTone.danger, _blockReasonLabel(reason)),
    Released() => (AbStatusTone.disabled, 'Disconnected'),
  };
}

/// [Climbing.rung] names the highest rung already SATISFIED, so each label here
/// is the rung ABOVE it — the work actually in progress. Naming the satisfied
/// rung instead would report "Authenticating" for the whole agent-absent
/// window, which is the longest stall a user hits and the one this surface
/// exists to distinguish from socket auth.
String _rungLabel(ConnRung rung) => switch (rung) {
  ConnRung.wanted => 'Locating agent',
  ConnRung.coords => 'Authenticating',
  ConnRung.socket => 'Waiting for agent',
  ConnRung.routable => 'Establishing session',
  // No rung above `established`: the supervisor emits Connected once it is
  // satisfied, so this arm is unreachable and must not claim a specific step.
  ConnRung.established => 'Connecting',
};

String _blockReasonLabel(BlockReason reason) => switch (reason) {
  // LICENSE_EXPIRED is the relay's verdict for "no active plan", which an
  // account that never subscribed hits too — the label must not presume a
  // lapsed subscription.
  BlockReason.licenseExpired => 'Plan or sign-in needed',
  BlockReason.agentOffline => 'Agent offline',
  BlockReason.sessionTakenOver => 'Taken over',
  BlockReason.superseded => 'Superseded',
  BlockReason.deviceRevoked => 'Device revoked',
  BlockReason.handshakeFailing => 'Handshake failing',
};

/// Human copy for a structured bridge/relay refusal, keyed by error CODE —
/// never by matching message text, which is the bridge's wording and not a
/// contract. Returns null for codes without dedicated copy so each surface
/// keeps its own fallback (usually the raw message).
String? friendlyErrorCopy(String? code) => switch (code) {
  // The bridge refuses every project verb with NOT_ALLOWED while the machine's
  // remote-access switch is off; its raw "mobile access is disabled on this
  // machine" names neither the switch nor where to find it.
  'NOT_ALLOWED' =>
    'Remote access is off on this machine. Turn it on in Antgrid on that '
        'computer — the Remote chip in the title bar.',
  // Same never-subscribed caveat as _blockReasonLabel's licenseExpired arm.
  'LICENSE_EXPIRED' =>
    'This account can\'t reach machines remotely right now. Sign in again, '
        'or check your plan.',
  // Isolated-session refusals (WorktreeErrorCode in
  // `bridge/src/worktrees/worktree-manager.ts`). An arm here REPLACES the
  // bridge's own message, so a code earns one only where a single sentence is
  // true of every producer. CONFLICT and CREATE_FAILED are deliberately absent:
  // each spans causes as unlike as a locked checkout and a repository with no
  // commit, so one sentence could only be vague enough to hide the actionable
  // one, and the raw message says which. DIRTY and UNPUSHED are absent too —
  // those are answered by the delete ladder's second question, and copy here
  // would turn a recoverable prompt into a dead end. Every arm names the
  // isolated SESSION rather than the worktree that backs it: the mechanism is
  // the bridge's business and is not settled.
  //
  // Every producer is registration- or availability-shaped (no longer
  // registered, manager or project path unavailable) rather than "the files are
  // gone", and three of the five fire on the delete path — so this must not
  // send the user back to delete.
  'WORKTREE_MISSING' =>
    'Antgrid can no longer reach this isolated session\'s workspace.',
  // Claims no cause: one producer throws after the workspace was already
  // removed and only the branch delete failed, another when the session would
  // not stop.
  'WORKTREE_DELETE_FAILED' =>
    'Antgrid couldn\'t finish deleting this isolated session.',
  // The producer is a build-time kill switch (WORKTREE_SESSIONS_SUPPORTED), not
  // a version gate — updating cannot clear it.
  'WORKTREE_UNSUPPORTED' =>
    'This machine\'s Antgrid can\'t create isolated sessions.',
  // Also produced by the plain branch RPC, and any banner code is rendered
  // through here, so it must not mention isolation.
  'NOT_GIT_REPOSITORY' => 'This project isn\'t a Git repository.',
  'UNKNOWN_BASE_BRANCH' =>
    'That base branch doesn\'t exist in this repository. Pick another one.',
  // One producer rejects ANY absolute path, including one well inside the
  // project, so the rule is "relative", not "inside". Names the key to edit
  // because the machine holding it may not be the one reading this.
  'WORKTREE_WORKING_DIR_UNSAFE' =>
    'This session\'s agent.workingDir must be a path relative to the isolated '
        'checkout. Fix it in antgrid.yaml on that machine.',
  _ => null,
};

/// One refusal, rendered: dedicated copy for [code], else the bridge's own
/// [message], else [fallback].
///
/// The precedence is the contract. A code that has dedicated copy is never shown
/// the bridge's raw wording — the arm exists precisely because that wording is
/// wrong for the reader — and a code without one is never shown a generic
/// sentence while the bridge has said something specific. [fallback] covers a
/// transport-shaped refusal carrying neither.
String sessionRefusalCopy(String? code, String? message, String fallback) =>
    friendlyErrorCopy(code) ?? message ?? fallback;

/// Copy for a machine whose advert lists no projects, keyed by the tri-state
/// machine-level `remoteAccessEnabled` flag: `false` is the machine's
/// remote-access switch (the NOT_ALLOWED verb refusal's copy — one switch, one
/// wording, and the arm is a literal above so the `!` cannot fire), `true` a
/// genuinely empty catalog, and `null` (no advert / flag-less older bridge)
/// the neutral offline copy. Shared by the projects drawer and the New Session
/// picker so the two surfaces can never describe the same machine two ways.
String emptyAdvertHint(bool? remoteAccessEnabled) =>
    switch (remoteAccessEnabled) {
      false => friendlyErrorCopy('NOT_ALLOWED')!,
      true => 'No projects on this machine yet',
      null => 'Machine offline',
    };

/// Maps [TerminalSessionState] to a status tone for the leading dot.
///
/// Green/red/grey and NOT the agent tones an agent session row uses for what
/// looks like the same three states: a terminal is a process, so "running" is
/// genuinely the good outcome and pairs against a red "exited". An agent that
/// stopped has simply finished a turn — nothing failed — which is why that side
/// paints rest as [AbStatusTone.agentIdle] and never as success/danger. Don't
/// unify the two on the strength of the shared word "running".
AbStatusTone sessionStateTone(TerminalSessionState state) {
  return switch (state) {
    TerminalSessionState.running => AbStatusTone.success,
    TerminalSessionState.exited => AbStatusTone.danger,
    TerminalSessionState.starting => AbStatusTone.disabled,
  };
}
