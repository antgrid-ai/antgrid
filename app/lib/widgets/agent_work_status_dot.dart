import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_status_dot.dart';
import '../services/control_plane_client.dart';

/// Canonical indicator for an [AgentWorkStatus], shared by the Recent list and
/// the sidebar so the four states read identically everywhere:
/// working (blue pulse) · attention (amber pulse — needs you) · error (red) ·
/// done (hollow green check).
class AgentWorkStatusDot extends StatelessWidget {
  const AgentWorkStatusDot({super.key, required this.status});

  final AgentWorkStatus status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case AgentWorkStatus.working:
        return const AbStatusDot(
          tone: AbStatusTone.info,
          size: AbDotSize.sm,
          style: AbDotStyle.filled,
          pulse: true,
        );
      case AgentWorkStatus.attention:
        return const AbStatusDot(
          tone: AbStatusTone.warning,
          size: AbDotSize.sm,
          style: AbDotStyle.filled,
          pulse: true,
        );
      case AgentWorkStatus.error:
        return const AbStatusDot(
          tone: AbStatusTone.danger,
          size: AbDotSize.sm,
          style: AbDotStyle.filled,
        );
      case AgentWorkStatus.done:
        return Stack(
          alignment: Alignment.center,
          children: [
            const AbStatusDot(
              tone: AbStatusTone.success,
              size: AbDotSize.sm,
              style: AbDotStyle.hollow,
            ),
            AbIcon(AbIcons.check, size: 8, color: context.antgrid.success),
          ],
        );
    }
  }
}
