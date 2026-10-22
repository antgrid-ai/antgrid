import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/recent_sessions.dart';
import '../services/operational_notice.dart';

const _kSuccessToastDuration = Duration(seconds: 4);
const _kFailureToastDuration = Duration(seconds: 8);

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

  void _show(ProjectScoped<OperationalNotice> event) {
    final id = event.entryId;
    final notice = event.message;
    // Decided when shown, not when raised: what matters is whether the user is
    // looking at that project now.
    final project = id == ref.read(selectedRegistrationIdProvider)
        ? null
        : ref.read(projectDisplayNameProvider(id)) ?? projectNameFromId(id);
    showAbToastOverlay(
      context,
      toast: AbToast(
        icon: notice.failed ? AbIcons.error : AbIcons.info,
        iconColor: notice.failed ? context.antgrid.error : null,
        title: notice.message,
        description: project,
      ),
      // A refusal usually carries git's or a hook's own explanation, which
      // takes longer to read than "Committed abc123" takes to glance at.
      duration: notice.failed ? _kFailureToastDuration : _kSuccessToastDuration,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
