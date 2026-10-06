import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_harness.dart';

Future<void> _pumpMenu(
  WidgetTester tester, {
  Alignment alignment = Alignment.centerLeft,
  Rect? bounds,
  VoidCallback? action,
  ValueChanged<String?>? result,
  int rows = 1,
}) async {
  await pumpAntgrid(
    tester,
    Align(
      alignment: alignment,
      child: Builder(
        builder: (context) => GestureDetector(
          onTap: () {
            final box = context.findRenderObject()! as RenderBox;
            showAbMenu<String>(
              context: context,
              anchorRect: box.localToGlobal(Offset.zero) & box.size,
              bounds: bounds,
              width: 200,
              entries: [
                const AbMenuItem(label: 'Settings', value: 'settings'),
                AbMenuSubmenu(
                  label: 'Help',
                  entries: [
                    for (var i = 0; i < rows; i++)
                      AbMenuItem(
                        label: 'Guide $i',
                        value: 'guide',
                        onTap: action,
                      ),
                    const AbMenuInfo(label: 'Version', value: Text('1.2.3')),
                  ],
                ),
              ],
            ).then((value) => result?.call(value));
          },
          child: const Text('Open menu'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'flyout escapes drawer bounds and selecting closes the whole route',
    (tester) async {
      String? selected;
      var invoked = false;
      await _pumpMenu(
        tester,
        bounds: const Rect.fromLTWH(0, 0, 220, 600),
        action: () => invoked = true,
        result: (value) => selected = value,
      );
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      final parent = tester.getRect(find.byType(AbMenu).first);
      final child = tester.getRect(find.byType(AbMenu).last);
      expect(child.left, greaterThanOrEqualTo(parent.right));
      expect(child.right, greaterThan(220));
      await tester.tap(find.text('Guide 0'));
      await tester.pumpAndSettle();
      expect(selected, 'guide');
      expect(invoked, isTrue);
      expect(find.byType(AbMenu), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('metadata is skipped and Tab stays inside the flyout', (
    tester,
  ) async {
    String? selected;
    await _pumpMenu(tester, result: (value) => selected = value);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'guide');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('flyout flips left at the right edge', (tester) async {
    await _pumpMenu(tester, alignment: Alignment.centerRight);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    final parent = tester.getRect(find.byType(AbMenu).first);
    final child = tester.getRect(find.byType(AbMenu).last);
    expect(child.right, lessThanOrEqualTo(parent.left));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('narrow desktop uses replacement list and restores Help focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpMenu(tester);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Back'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Guide 0'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'mobile replaces the list and system Back returns then dismisses',
      (tester) async {
        await _pumpMenu(tester);
        await tester.tap(find.text('Help'));
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsNothing);
        expect(find.text('Back'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AbMenu), findsNothing);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets('outside click dismisses parent and flyout', (tester) async {
    await _pumpMenu(tester);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(790, 590));
    await tester.pumpAndSettle();
    expect(find.byType(AbMenu), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('keyboard opens, returns to Help, and dismisses', (tester) async {
    await _pumpMenu(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Guide 0'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('Guide 0'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Guide 0'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Guide 0'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AbMenu), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'hover opens after delay and crossing the gap keeps the flyout open',
    (tester) async {
      await _pumpMenu(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(790, 590));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Help')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Guide 0'), findsNothing);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(find.text('Guide 0'), findsOneWidget);
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.moveTo(tester.getCenter(find.text('Guide 0')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Guide 0'), findsOneWidget);
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();
      expect(find.text('Guide 0'), findsNothing);
      expect(find.text('Help'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('long submenu scrolls inside a short viewport', (tester) async {
    tester.view.physicalSize = const Size(800, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpMenu(tester, rows: 20);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Version'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Version')).bottom, lessThanOrEqualTo(240));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
