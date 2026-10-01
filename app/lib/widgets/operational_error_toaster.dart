import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/recent_sessions.dart';

/// Invisible host for every warm project's transient operational errors and
/// feedback ([operationalErrorsProvider]).
///
/// Git op results, checkout and branch-list failures, and session refusals
/// have no in-context UI of their own (unlike file-read/search, which render
/// their error where they happen). This surfaces them as a toast so they aren't
/// silently swallowed — without a persistent drawer dot (reserved for
/// structural config errors). One from a project other than the focused one
/// names that project, since the message alone reads as being about what is
/// on screen.
///
/// Every source is an event stream on a service, never stored state. A stored
/// error outlives its toast, and the state providers re-emit it on every focus
/// switch and to every new listener — so a switch back to a session, or this
/// widget remounting, would toast a failure the user had already seen. An
/// event that lands while nothing listens is gone instead, which is why this
/// wraps the app's root screen (`AppShell`, `DemoHome`) rather than mounting in
/// the workspace: that unmounts behind the New Session canvas while the
/// sidebar, which can still stop a session, stays up.
class OperationalErrorToaster extends ConsumerStatefulWidget {
  const OperationalErrorToaster({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OperationalErrorToaster> createState() =>
      _OperationalErrorToasterState();
}

class _OperationalErrorToasterState
    extends ConsumerState<OperationalErrorToaster> {
  late final void Function() _stopListening;

  @override
  void initState() {
    super.initState();
    _stopListening = listenToEvents(ref, operationalErrorsProvider, _show);
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  void _show(ProjectScoped<String> error) {
    final id = error.entryId;
    // Decided when shown, not when raised: what matters is whether the user is
    // looking at that project now.
    final project = id == ref.read(selectedRegistrationIdProvider)
        ? null
        : ref.read(projectDisplayNameProvider(id)) ?? projectNameFromId(id);
    showAbToastOverlay(
      context,
      toast: AbToast(
        icon: AbIcons.info,
        title: error.message,
        description: project,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
