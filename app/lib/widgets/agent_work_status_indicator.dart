import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/agent_work_status.dart';

/// The Carbon glyph for each work status. Mirrors the families the Ab dot
/// uses: only statuses that want something from the user carry a loud colour,
/// and `done` is the same idle grey as a session that never ran.
CarbonIconIndicatorKind agentWorkStatusIndicatorKind(AgentWorkStatus status) =>
    switch (status) {
      AgentWorkStatus.working => CarbonIconIndicatorKind.inProgress,
      AgentWorkStatus.attention => CarbonIconIndicatorKind.cautionMinor,
      AgentWorkStatus.error => CarbonIconIndicatorKind.failed,
      AgentWorkStatus.unread => CarbonIconIndicatorKind.normal,
      AgentWorkStatus.done => CarbonIconIndicatorKind.notStarted,
    };

/// The Carbon support colour for a status dot drawn by hand on an agent mark,
/// where a full indicator glyph does not fit.
///
/// Every status has a dot (the Ab spec draws one for all five), so this never
/// returns null today; the type leaves room for a status that shows none.
/// [agentWorkStatusDotHollow] says which dot is drawn as a ring.
Color? agentWorkStatusDotColor(CarbonThemeData t, AgentWorkStatus s) =>
    CarbonIconIndicator.colorOf(t, agentWorkStatusIndicatorKind(s));

/// Only `done` is a ring, so it stays distinguishable from the live states
/// without relying on its grey.
bool agentWorkStatusDotHollow(AgentWorkStatus s) => s == AgentWorkStatus.done;

/// A glyph-only indicator for a work status, named by [semanticLabel] as its
/// tooltip and accessible name.
class CarbonAgentWorkStatusIndicator extends StatelessWidget {
  const CarbonAgentWorkStatusIndicator({
    super.key,
    required this.status,
    required this.semanticLabel,
  });

  final AgentWorkStatus status;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => CarbonIconIndicator(
    kind: agentWorkStatusIndicatorKind(status),
    label: semanticLabel,
    compact: true,
  );
}
