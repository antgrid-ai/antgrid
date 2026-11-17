import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/widgets/agent_work_status_dot.dart';
import 'package:antgrid/widgets/agent_work_status_indicator.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

void main() {
  test('every status maps to its own indicator kind', () {
    final kinds = {
      for (final s in AgentWorkStatus.values) s: agentWorkStatusIndicatorKind(s),
    };
    expect(kinds, {
      AgentWorkStatus.working: CarbonIconIndicatorKind.inProgress,
      AgentWorkStatus.attention: CarbonIconIndicatorKind.cautionMinor,
      AgentWorkStatus.error: CarbonIconIndicatorKind.failed,
      AgentWorkStatus.unread: CarbonIconIndicatorKind.normal,
      AgentWorkStatus.done: CarbonIconIndicatorKind.notStarted,
    });
    expect(kinds.values.toSet(), hasLength(AgentWorkStatus.values.length));
  });

  test('the hollow dot is the Ab spec hollow dot', () {
    for (final s in AgentWorkStatus.values) {
      expect(
        agentWorkStatusDotHollow(s),
        agentWorkStatusDotSpec(s).style == AbDotStyle.hollow,
        reason: s.name,
      );
    }
  });

  for (final brightness in Brightness.values) {
    test('every status has a distinct-enough dot colour in ${brightness.name}',
        () {
      final t = CarbonThemeData.forBrightness(
        brightness,
        density: CarbonDensity.compact,
      );
      for (final s in AgentWorkStatus.values) {
        final color = agentWorkStatusDotColor(t, s);
        expect(color, isNotNull, reason: s.name);
        expect(
          color,
          CarbonIconIndicator.colorOf(t, agentWorkStatusIndicatorKind(s)),
          reason: s.name,
        );
      }
      final live = {
        for (final s in AgentWorkStatus.values)
          if (s != AgentWorkStatus.unread && s != AgentWorkStatus.working)
            agentWorkStatusDotColor(t, s),
      };
      expect(live, hasLength(3));
    });
  }

  testWidgets('each status renders a named glyph indicator', (tester) async {
    final handle = tester.ensureSemantics();
    for (final s in AgentWorkStatus.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: AbCarbonScope(
              child: Center(
                child: CarbonAgentWorkStatusIndicator(
                  status: s,
                  semanticLabel: 'Status ${s.name}',
                ),
              ),
            ),
          ),
        ),
      );
      final indicator = tester.widget<CarbonIconIndicator>(
        find.byType(CarbonIconIndicator),
      );
      expect(indicator.kind, agentWorkStatusIndicatorKind(s), reason: s.name);
      expect(indicator.compact, isTrue);
      expect(find.bySemanticsLabel('Status ${s.name}'), findsWidgets);
      expect(abWidgetsInScope(tester), isEmpty, reason: s.name);
    }
    handle.dispose();
  });
}
