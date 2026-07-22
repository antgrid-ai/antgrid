import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/context_meter.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('ContextMeter', () {
    testWidgets('renders nothing when contextWindow is null', (tester) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: 1000),
        contextWindow: null,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      expect(
        find.descendant(
          of: find.byType(ContextMeter),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets('renders an empty ring with –% when occupancy is unknown', (
      tester,
    ) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: null),
        contextWindow: 195000,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      expect(
        find.descendant(
          of: find.byType(ContextMeter),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      expect(find.text('–%'), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();

      expect(find.text('CONTEXT · –%'), findsOneWidget);
      expect(find.text('— / 195.0k tokens'), findsOneWidget);
      expect(find.textContaining('free'), findsNothing);
    });

    testWidgets('shows the occupancy percent beside the ring', (tester) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: 30000),
        contextWindow: 200000,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      expect(find.text('15%'), findsOneWidget);
    });

    testWidgets('renders nothing when contextWindow is zero', (tester) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: 1000),
        contextWindow: 0,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      expect(
        find.descendant(
          of: find.byType(ContextMeter),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets('45% usage paints and exposes 45%', (tester) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: 87750),
        contextWindow: 195000,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      expect(
        find.descendant(
          of: find.byType(ContextMeter),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('45%'), findsOneWidget);
    });

    testWidgets('tap opens popover with tokens and input/output/cache lines', (
      tester,
    ) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(
          totalTokens: 87400,
          inputTokens: 60000,
          outputTokens: 27400,
          cacheReadTokens: 12000,
        ),
        contextWindow: 195000,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();

      expect(find.text('87.4k / 195.0k tokens'), findsOneWidget);
      expect(find.text('107.6k free'), findsOneWidget);
      expect(find.text('input 60.0k'), findsOneWidget);
      expect(find.text('output 27.4k'), findsOneWidget);
      expect(find.text('cache read 12.0k'), findsOneWidget);
    });

    testWidgets('popover clamps free tokens to zero when usage is over cap', (
      tester,
    ) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: 250000),
        contextWindow: 200000,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();

      expect(find.text('0 free'), findsOneWidget);
      expect(find.text('-50.0k free'), findsNothing);
    });

    // codex's `total` is a running sum across every API round-trip in the
    // session (multiple tool-call round-trips inflate it well past what's
    // actually sitting in the context window); `last` is the most recent
    // turn's context size, which is what the meter should reflect. Mirrors
    // codex-rs/tui/src/chatwidget.rs `context_remaining_percent`, which
    // sources the percent from `last_token_usage`, never `total_token_usage`.
    testWidgets(
      'prefers last-turn usage over cumulative total when both are present',
      (tester) async {
        const usage = AgentUsage(
          total: AgentTokenUsage(totalTokens: 97500),
          last: AgentTokenUsage(totalTokens: 3900),
          contextWindow: 195000,
        );
        await _pump(tester, const ContextMeter(usage: usage));

        expect(find.bySemanticsLabel('2%'), findsOneWidget);
      },
    );

    testWidgets('falls back to total when last is absent (e.g. opencode)', (
      tester,
    ) async {
      const usage = AgentUsage(
        total: AgentTokenUsage(totalTokens: 87750),
        contextWindow: 195000,
      );
      await _pump(tester, const ContextMeter(usage: usage));

      expect(find.bySemanticsLabel('45%'), findsOneWidget);
    });
  });

  group('MeterPainter', () {
    testWidgets('uses accent below 50%, warning 50-90%, error above 90%', (
      tester,
    ) async {
      late AbColors colors;
      await _pump(
        tester,
        Builder(
          builder: (context) {
            colors = context.antgrid;
            return const SizedBox.shrink();
          },
        ),
      );

      final low = MeterPainter(fraction: 0.45, colors: colors);
      final mid = MeterPainter(fraction: 0.7, colors: colors);
      final high = MeterPainter(fraction: 0.95, colors: colors);

      expect(low.color, colors.accent);
      expect(mid.color, colors.warning);
      expect(high.color, colors.error);
    });
  });
}
