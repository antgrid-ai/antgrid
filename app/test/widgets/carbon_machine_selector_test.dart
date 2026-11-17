import 'dart:ui' show CheckedState;

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/carbon_machine_selector.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _machines = {'local': 'Local machine', 'm1': 'Laptop'};

Future<void> _pump(
  WidgetTester tester, {
  Map<String, String> machines = _machines,
  String currentId = 'm1',
  String name = 'Laptop',
  bool connected = true,
  bool wide = false,
  double scale = 1,
  ValueChanged<String>? onPicked,
}) => tester.pumpWidget(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAbTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: Scaffold(
      body: AbCarbonScope(
        child: Align(
          alignment: Alignment.topLeft,
          child: CarbonMachineSelector(
            machines: machines,
            currentId: currentId,
            name: name,
            connected: connected,
            wide: wide,
            onPicked: onPicked ?? (_) {},
          ),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byType(CarbonButton));
  await tester.pumpAndSettle();
}

Finder _dotFinder() => find.descendant(
  of: find.byType(CarbonMachineSelector),
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle,
  ),
);

void main() {
  testWidgets('shows the machine name', (tester) async {
    await _pump(tester);
    expect(find.text('Laptop'), findsOneWidget);
  });

  testWidgets('the trigger says what it changes and whether it is offline', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(
      tester.getSemantics(find.text('Laptop')),
      isSemantics(label: 'Machine: Laptop, change', isButton: true),
    );
    await _pump(tester, connected: false);
    expect(
      tester.getSemantics(find.text('Laptop')),
      isSemantics(label: 'Machine: Laptop, offline, change', isButton: true),
    );
    handle.dispose();
  });

  testWidgets('menu lists every machine with the current one checked', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await _open(tester);

    expect(find.text('Local machine'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Laptop').last).flagsCollection.isChecked,
      CheckedState.isTrue,
    );
    expect(
      tester.getSemantics(find.text('Local machine')).flagsCollection.isChecked,
      CheckedState.isFalse,
    );
    handle.dispose();
  });

  testWidgets('picking another machine reports its id', (tester) async {
    final picked = <String>[];
    await _pump(tester, onPicked: picked.add);
    await _open(tester);
    await tester.tap(find.text('Local machine'));
    await tester.pumpAndSettle();
    expect(picked, ['local']);
  });

  testWidgets('the dot sits inside the trigger, before the name', (
    tester,
  ) async {
    await _pump(tester);
    final button = tester.getRect(find.byType(CarbonButton));
    final dot = tester.getRect(_dotFinder());
    expect(button.contains(dot.center), isTrue);
    expect(dot.right, lessThan(tester.getRect(find.text('Laptop')).left));
  });

  testWidgets('dot is filled when connected, outlined when not', (
    tester,
  ) async {
    await _pump(tester);
    final colors = CarbonTheme.of(tester.element(_dotFinder())).colors;
    final on =
        tester.widget<DecoratedBox>(_dotFinder()).decoration as BoxDecoration;
    expect(on.color, colors.supportSuccess);

    await _pump(tester, connected: false);
    final off =
        tester.widget<DecoratedBox>(_dotFinder()).decoration as BoxDecoration;
    expect(off.color, isNull);
    expect((off.border! as Border).top.color, colors.iconSecondary);
  });

  testWidgets('a long name stays within the width at 320 and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final name = 'N' * 60;
    await _pump(tester, machines: {'m1': name}, name: name, scale: 2);

    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(CarbonMachineSelector));
    expect(size.width, lessThanOrEqualTo(CarbonSpacing.spacing05 * 9));
    expect(size.height, lessThanOrEqualTo(CarbonSizes.xl));
  });

  testWidgets('touch density gives a 44 target', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pump(tester);
      expect(
        tester.getSize(find.byType(CarbonButton)).height,
        greaterThanOrEqualTo(44),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
