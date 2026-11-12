import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show MaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Text(
      '${theme.scheme.name} ${theme.density.name} '
      '${Directionality.of(context).name} '
      '${MediaQuery.textScalerOf(context).scale(10)}',
    );
  }
}

void main() {
  testWidgets('provides theme, direction, text scale and localizations', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      Builder(
        builder: (context) {
          MaterialLocalizations.of(context);
          return const _Probe();
        },
      ),
      dir: TextDirection.rtl,
      textScale: 2,
    );
    expect(find.text('white compact rtl 20.0'), findsOneWidget);
  });

  testWidgets('live theme and re-pumps keep state', (tester) async {
    await pumpCarbon(tester, const _Probe());
    final state = tester.state(find.byType(_Probe));

    await setCarbonTheme(
      tester,
      CarbonThemeData(
        scheme: CarbonThemeScheme.gray90,
        density: CarbonDensity.touch,
      ),
    );
    expect(find.text('gray90 touch ltr 10.0'), findsOneWidget);
    expect(tester.state(find.byType(_Probe)), same(state));

    await pumpCarbon(tester, const _Probe(), dir: TextDirection.rtl);
    expect(find.text('white compact rtl 10.0'), findsOneWidget);
    expect(tester.state(find.byType(_Probe)), same(state));
  });

  testWidgets('carbonHarness remounts cleanly', (tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(carbonHarness(const _Probe()));
      await tester.pumpWidget(
        carbonHarness(const _Probe(), dir: TextDirection.rtl),
      );
    }
    expect(find.text('white compact rtl 10.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back pops a pushed route', (tester) async {
    final harness = await pumpCarbon(tester, const _Probe());
    harness.navigatorKey.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const Text('second'),
      ),
    );
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    await harness.back(tester);
    await tester.pump();
    expect(find.text('second'), findsNothing);
  });
}
