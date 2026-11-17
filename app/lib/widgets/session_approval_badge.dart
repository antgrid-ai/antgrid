import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_chip.dart';
import '../models/session_entry.dart';
import '../providers/sessions.dart';
import 'carbon_session_badges.dart';

class SessionApprovalBadge extends StatelessWidget {
  const SessionApprovalBadge({super.key, required this.session});

  final SessionEntry? session;

  @override
  Widget build(BuildContext context) {
    if (session?.approvalPolicy != 'bypass') return const SizedBox.shrink();
    return AbChip.system(
      key: const Key('session-yolo-badge'),
      label: 'YOLO',
      color: context.antgrid.error,
    );
  }
}

/// The agent bar's badge for the focused session, in Carbon; the Recent rows
/// still draw [SessionApprovalBadge].
class ActiveSessionApprovalBadge extends ConsumerWidget {
  const ActiveSessionApprovalBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AbCarbonScope(
    child: CarbonSessionApprovalBadge(
      session: ref.watch(activeSessionProvider),
    ),
  );
}
