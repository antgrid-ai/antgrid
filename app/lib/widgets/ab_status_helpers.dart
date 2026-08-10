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
  _ => null,
};

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
AbStatusTone sessionStateTone(TerminalSessionState state) {
  return switch (state) {
    TerminalSessionState.running => AbStatusTone.success,
    TerminalSessionState.exited => AbStatusTone.danger,
    TerminalSessionState.starting => AbStatusTone.disabled,
  };
}
