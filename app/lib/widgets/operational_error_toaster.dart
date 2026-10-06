import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/recent_sessions.dart';

/// Toasts every warm project's transient errors. Wraps the root screen: its
/// sources are event streams, so an event landing unheard is gone for good.
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
