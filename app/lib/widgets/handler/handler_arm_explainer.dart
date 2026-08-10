import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_confirm_dialog.dart';
import '../../providers/first_run.dart';
import '../../services/handler_service.dart';
import 'handler_item_status.dart';

/// Body copy for the first-arm explainer. Top-level so the copy matrix is
/// unit-testable without pumping a dialog.
///
/// The coverage line mirrors the catalog contract (see agentCatalogProvider):
/// `false` is a bridge saying "cannot watch" — reuse [unwatchableNotice], the
/// warning that otherwise lives only in the shield tooltip — while `null`
/// means nobody has said anything, so the copy claims neither.
String handlerArmExplainerBody({
  required bool? agentObservable,
  String? agentLabel,
}) {
  const base =
      "Handler watches this session while you're away. When the agent pauses "
      'on a question or a permission, Handler answers what it safely can and '
      'queues the rest for you.';
  return switch (agentObservable) {
    true => base,
    false => '$base\n\n${unwatchableNotice(agentLabel)}',
    null =>
      "$base\n\nThis agent hasn't reported what Handler can see here, so it "
          'may stay silent.',
  };
}

/// Shows the one-time "what is Handler" explainer. Returns true when the user
/// confirmed arming.
Future<bool> showHandlerArmExplainer(
  BuildContext context, {
  required bool? agentObservable,
  String? agentLabel,
}) => AbConfirmDialog.show(
  context: context,
  title: 'Arm Handler',
  body: handlerArmExplainerBody(
    agentObservable: agentObservable,
    agentLabel: agentLabel,
  ),
  confirmLabel: 'Arm Handler',
  cancelLabel: 'Not now',
);

/// The single first-arm flow, shared by the header shield and the away-moment
/// hint so the two can never drift: explainer while [FirstRunState.handlerArmedOnce]
/// is false → arm on confirm → latch the flag on EVERY successful arm.
///
/// Cancelling arms nothing and leaves the flag false, so the next tap explains
/// again — "never shown again" starts at the first successful arm. Takes a
/// [ProviderContainer], not a WidgetRef: the caller's widget may be gone by the
/// time the dialog resolves. [context] is only used before the await.
Future<void> armWithFirstRunExplainer({
  required BuildContext context,
  required ProviderContainer container,
  required HandlerService service,
  required String terminalId,
  required bool notifyOnly,
  required bool? agentObservable,
  String? agentLabel,
}) async {
  if (!container.read(firstRunProvider).handlerArmedOnce) {
    final ok = await showHandlerArmExplainer(
      context,
      agentObservable: agentObservable,
      agentLabel: agentLabel,
    );
    if (!ok) return;
  }
  service.arm(terminalId: terminalId, notifyOnly: notifyOnly);
  container.read(firstRunProvider.notifier).markHandlerArmed();
}
