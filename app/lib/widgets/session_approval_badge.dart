import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/widgets/ab_chip.dart';
import '../models/session_entry.dart';
import '../providers/sessions.dart';

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

class ActiveSessionApprovalBadge extends ConsumerWidget {
  const ActiveSessionApprovalBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      SessionApprovalBadge(session: ref.watch(activeSessionProvider));
}
