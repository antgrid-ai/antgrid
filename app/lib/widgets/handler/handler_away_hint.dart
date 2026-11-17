import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_carbon.dart';
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
///
/// Owns a Carbon scope at a fixed position, and arms from a context under it:
/// the arm sheet is a Carbon modal and follows its presenting context's theme.
class HandlerAwayHint extends ConsumerWidget {
  const HandlerAwayHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(handlerAwayHintProvider);
    final activeId = ref.watch(activeSessionIdProvider);
    final service = serviceWhenReady(ref, handlerServiceProvider);
    final coverage = ref.watch(focusedSessionCoverageProvider);
    return AbCarbonScope(
      child: !show
          ? const SizedBox.shrink()
          : Builder(
              builder: (scoped) => CarbonNotification(
                // A teaching hint, not an alert: the info kind stays off the
                // warning and error palette.
                subtitle:
                    "Still waiting on you — Handler can watch this session and "
                    "reply while you're away.",
                closeLabel: "Dismiss — won't show again",
                action: CarbonNotificationAction(
                  label: 'Arm',
                  onPressed: service == null || activeId == null
                      ? null
                      : () {
                          // Fire-and-forget: past the sheet await everything
                          // runs on the container, never this widget's ref, and
                          // none of it can throw (the arm send is a plain
                          // fire-and-forget too).
                          unawaited(
                            armWithSheet(
                              context: scoped,
                              container: ref.container,
                              terminalId: activeId,
                              agentObservable: coverage.observable,
                              agentLabel: coverage.agentLabel,
                              judgeCapable: coverage.judgeCapable,
                            ),
                          );
                        },
                ),
                onClose: () => ref
                    .read(firstRunProvider.notifier)
                    .dismissHandlerAwayHint(),
              ),
            ),
    );
  }
}
