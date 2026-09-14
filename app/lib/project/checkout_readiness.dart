import '../connection/supervisor_state.dart';
import '../models/terminal_models.dart';

/// Can the FOCUSED checkout be used right now?
///
/// Deliberately distinct from [SupervisorStatus], which is machine-scoped
/// (RelayConnectionManager.peek normalises its key with baseDeviceUuid) and
/// answers "is this machine reachable". A surface asking whether a machine is
/// up reads supervisorStatusProvider + connectionDisplayInfo; a surface asking
/// whether the workspace is usable reads checkoutReadinessProvider +
/// readinessDisplayInfo. Nothing enforces that split but this comment.
enum CheckoutReadiness {
  cold,
  blocked,
  reachingMachine,
  openingSession,
  loadingScreen,
  stalled,
  ready,
}

// There is no `loadingHistory`:
// `_awaitingHistoryIds` membership always describes a cold pull
// (`_applySnapshot` consumes the claim before it paints), so a stage derived
// from it can never distinguish "painted, history still loading" from
// `loadingScreen`.

CheckoutReadiness composeReadiness({
  required bool isRemote,
  required bool sessionResolved,
  SupervisorStatus? status,
  TerminalState? terminal,
}) {
  if (isRemote) {
    // Local mode has no supervisor at all; skipping the ladder is what stops a
    // local checkout parking on `reachingMachine` forever.
    if (status is Blocked) return CheckoutReadiness.blocked;
    if (status == null || status is Released) return CheckoutReadiness.cold;
    if (status is! Connected) return CheckoutReadiness.reachingMachine;
  }
  if (!sessionResolved || terminal == null) {
    return CheckoutReadiness.openingSession;
  }
  switch (terminal.attach) {
    case CheckoutAttachStatus.failed:
      return CheckoutReadiness.stalled;
    case CheckoutAttachStatus.unknown:
    case CheckoutAttachStatus.attaching:
      return CheckoutReadiness.loadingScreen;
    case CheckoutAttachStatus.ready:
      return CheckoutReadiness.ready;
  }
}
