import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/rows/usage_footer_row.dart';

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('renders in/out/total and cached segments', (tester) async {
    const usage = AgentTokenUsage(
      inputTokens: 1500,
      outputTokens: 200,
      totalTokens: 1700,
      cacheReadTokens: 8200,
    );

    await _pump(tester, const UsageFooterRow(usage: usage));

    expect(
      find.text('1.5k in · 200 out · 1.7k tok · 8.2k cached'),
      findsOneWidget,
    );
  });

  testWidgets(
    'omits cached when zero and renders nothing when all fields null',
    (tester) async {
      const partial = AgentTokenUsage(
        inputTokens: 100,
        outputTokens: 50,
        totalTokens: 150,
        cacheReadTokens: 0,
      );
      await _pump(tester, const UsageFooterRow(usage: partial));
      expect(find.text('100 in · 50 out · 150 tok'), findsOneWidget);

      await _pump(tester, const UsageFooterRow(usage: AgentTokenUsage()));
      expect(find.byType(Text), findsNothing);
    },
  );
}
