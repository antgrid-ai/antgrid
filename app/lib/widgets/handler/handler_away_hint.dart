import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../models/handler_state.dart';
import '../../providers/first_run.dart';
import '../../providers/handler_discovery.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import 'handler_arm_explainer.dart';

/// The away-moment teaching hint: the focused session has been blocked on the
/// user for a while and Handler is not armed on it. Self-expiring by
/// construction — the banner unmounts the moment the status leaves attention,
/// the session is armed, or focus moves; dismiss is the persistent kill.
///
/// Mounted on desktop AND mobile deliberately: the away moment is exactly when
/// a user is glancing at their phone.
class HandlerAwayHint extends ConsumerWidget {
  const HandlerAwayHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(handlerAwayHintProvider)) return const SizedBox.shrink();
    final activeId = ref.watch(activeSessionIdProvider);
    final service = serviceWhenReady(ref, handlerServiceProvider);
    final handlerState =
        ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
    final coverage = ref.watch(focusedSessionCoverageProvider);
    return AbInlineBanner(
      text:
          "Still waiting on you — Handler can watch this session and reply "
          "while you're away.",
      // A teaching hint, not an alert — stays off the accent/warning palette.
      color: context.antgrid.textSecondary,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbButton(
            label: 'ARM',
            compact: true,
            onTap: service == null || activeId == null
                ? null
                : () {
                    // Fire-and-forget: past the explainer await everything runs
                    // on the container, never this widget's ref, and none of it
                    // can throw (the arm send is a plain fire-and-forget too).
                    unawaited(
                      armWithFirstRunExplainer(
                        context: context,
                        container: ref.container,
                        service: service,
                        terminalId: activeId,
                        notifyOnly: handlerState.defaultNotifyOnly,
                        agentObservable: coverage.observable,
                        agentLabel: coverage.agentLabel,
                      ),
                    );
                  },
          ),
          const SizedBox(width: AbTokens.space6),
          AbIconButton(
            icon: AbIcons.close,
            tooltip: "Dismiss — won't show again",
            onTap: () =>
                ref.read(firstRunProvider.notifier).dismissHandlerAwayHint(),
          ),
        ],
      ),
    );
  }
}
