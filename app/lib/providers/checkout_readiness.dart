import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/checkout_readiness.dart';
import '../project/project_session_registry.dart';
import 'agent_transport.dart';
import 'providers.dart';
import 'supervisor_status.dart';
import 'value_controller.dart';

/// Peek-only and non-dialling: safe to `read` from a tap handler.
final checkoutReadinessProvider = Provider.autoDispose<CheckoutReadiness>((
  ref,
) {
  final target = ref.watch(selectedTargetProvider);
  final id = target?.registrationId;
  if (id == null) return CheckoutReadiness.cold;
  // `selectedTargetProvider?.isLocal`, not focusedIsRelayProvider: the latter
  // answers by scanning the machine inventory for a matching deviceUuid, so a
  // cold launch whose inventory has not loaded reads a genuinely remote project
  // as local and skips the ladder entirely. The blocking-error gate on the same
  // screen already uses this predicate.
  final isRemote = target!.isLocal == false;
  return composeReadiness(
    isRemote: isRemote,
    sessionResolved: ref.watch(projectSessionProvider(id)).hasValue,
    status: isRemote ? ref.watch(supervisorStatusProvider(id)).value : null,
    terminal: ref.watch(terminalStateProvider).value,
  );
});

/// Epoch ms the user last activated the focused entry — the honest answer to
/// "how long have I been waiting". Stamped by activateDrawerEntryById, read by
/// the boot screen and the readiness chip so both count from the same instant.
/// A per-phase counter that resets on every advance reads as progress where
/// there is none, and a counter stamped when the pane finally mounts shows "2s"
/// to a user who has waited forty.
final focusedWaitStartedAtProvider =
    NotifierProvider<ValueController<int?>, int?>(() => ValueController(null));
