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
  BlockReason.licenseExpired => 'License expired',
  BlockReason.agentOffline => 'Agent offline',
  BlockReason.sessionTakenOver => 'Taken over',
  BlockReason.superseded => 'Superseded',
  BlockReason.deviceRevoked => 'Device revoked',
  BlockReason.handshakeFailing => 'Handshake failing',
};

/// Maps [TerminalSessionState] to a status tone for the leading dot.
AbStatusTone sessionStateTone(TerminalSessionState state) {
  return switch (state) {
    TerminalSessionState.running => AbStatusTone.success,
    TerminalSessionState.exited => AbStatusTone.danger,
    TerminalSessionState.starting => AbStatusTone.disabled,
  };
}
