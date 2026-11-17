import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/carbon_empty_state.dart';
import 'package:antgrid/widgets/memory/memory_empty_state.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  CarbonDensity density = CarbonDensity.compact,
  double textScale = 1.0,
  Size size = const Size(400, 400),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: AbCarbonScope(
        density: density,
        child: Scaffold(
          body: Center(
            child: SizedBox(width: size.width, height: size.height, child: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  CarbonEmptyState full({bool error = false}) => CarbonEmptyState(
    heading: 'Nothing here',
    body: 'Files you open show up in this pane.',
    icon: CarbonIcons.folder,
    error: error,
    action: CarbonButton(label: 'Retry', onPressed: () {}),
  );

  testWidgets('renders heading, body, icon and action', (tester) async {
    await _pump(tester, full());

    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Files you open show up in this pane.'), findsOneWidget);
    expect(find.byType(CarbonIcon), findsOneWidget);
    expect(find.byType(CarbonStatusIcon), findsNothing);
    expect(find.bySemanticsLabel('Retry'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('optional parts are omitted', (tester) async {
    await _pump(tester, const CarbonEmptyState(heading: 'Just a heading'));

    expect(find.text('Just a heading'), findsOneWidget);
    expect(find.byType(CarbonIcon), findsNothing);
    expect(find.byType(CarbonButton), findsNothing);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('error variant leads with the status icon instead of the glyph', (
    tester,
  ) async {
    await _pump(tester, full(error: true));

    expect(find.byType(CarbonStatusIcon), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is CarbonIcon && w.icon == CarbonIcons.folder,
      ),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is CarbonIcon && w.icon == CarbonIcons.errorFilled,
      ),
      findsOneWidget,
    );
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('a custom icon widget replaces the glyph', (tester) async {
    await _pump(
      tester,
      const CarbonEmptyState(
        heading: 'Custom',
        iconWidget: SizedBox(key: ValueKey('custom-icon'), width: 8, height: 8),
      ),
    );

    expect(find.byKey(const ValueKey('custom-icon')), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final density in CarbonDensity.values) {
      testWidgets('clean guard, ${brightness.name} ${density.name}', (
        tester,
      ) async {
        await _pump(
          tester,
          full(),
          brightness: brightness,
          density: density,
        );

        expect(abWidgetsInScope(tester), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('centres in a tall pane', (tester) async {
    await _pump(tester, full());

    final pane = tester.getRect(find.byType(CarbonEmptyState));
    final heading = tester.getCenter(find.text('Nothing here'));
    expect((heading.dx - pane.center.dx).abs(), lessThan(1));
    expect(heading.dy, greaterThan(pane.top));
    expect(heading.dy, lessThan(pane.bottom));
  });

  testWidgets('scrolls instead of overflowing in a short pane at 2.0 scale', (
    tester,
  ) async {
    await _pump(
      tester,
      full(),
      textScale: 2.0,
      size: const Size(240, 120),
    );

    expect(tester.takeException(), isNull);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(Scrollable), const Offset(0, -300));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('MemoryEmptyState maps onto the shared widget', (tester) async {
    await _pump(
      tester,
      MemoryEmptyState(
        title: 'No memories yet',
        subtitle: 'Findings agents save appear here.',
        icon: CarbonIcons.folder,
        action: CarbonButton(label: 'Add', onPressed: () {}),
      ),
    );

    final shared = tester.widget<CarbonEmptyState>(
      find.byType(CarbonEmptyState),
    );
    expect(shared.heading, 'No memories yet');
    expect(shared.body, 'Findings agents save appear here.');
    expect(shared.icon, CarbonIcons.folder);
    expect(shared.error, isFalse);
    expect(shared.action, isNotNull);
    expect(abWidgetsInScope(tester), isEmpty);
  });
}
