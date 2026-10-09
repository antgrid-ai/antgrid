import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/design/widgets/ab_toolbar.dart';
import 'package:antgrid/design/widgets/ab_touch_sizing.dart';

import '../test_harness.dart';

const _android = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.android,
});
const _windows = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
});

void _sizeView(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = logical * 3;
  addTearDown(tester.view.reset);
}

const _phone = Size(390, 844);
const _landscapePhone = Size(844, 390);
const _tablet = Size(820, 1180);

Future<double> _extentAt(WidgetTester tester, Size view) async {
  _sizeView(tester, view);
  late double extent;
  await pumpAntgrid(
    tester,
    Builder(
      builder: (context) {
        extent = AbTouchSizing.extentOf(context);
        return const SizedBox();
      },
    ),
  );
  return extent;
}

void main() {
  testWidgets('phones in either orientation get the touch extent', (
    tester,
  ) async {
    expect(await _extentAt(tester, _phone), AbTokens.touchControlMin);
    expect(await _extentAt(tester, _landscapePhone), AbTokens.touchControlMin);
  }, variant: _android);

  testWidgets('a tablet keeps desktop sizing', (tester) async {
    expect(await _extentAt(tester, _tablet), 0);
  }, variant: _android);

  testWidgets('desktop never touch-sizes, even at phone width', (
    tester,
  ) async {
    expect(await _extentAt(tester, _phone), 0);
  }, variant: _windows);

  testWidgets('a standalone button reserves the touch extent around a '
      'compact box', (tester) async {
    _sizeView(tester, _phone);
    await pumpAntgrid(tester, AbButton(label: 'Retry', onTap: () {}));
    final footprint = tester.getSize(find.byType(AbButton));
    expect(footprint.height, AbTokens.touchControlMin);
    final box = tester.getSize(
      find.descendant(of: find.byType(AbButton), matching: find.byType(Container)).first,
    );
    expect(box.height, lessThan(AbTokens.touchControlMin));
  }, variant: _android);

  testWidgets('a compact row keeps its height; its controls widen only', (
    tester,
  ) async {
    _sizeView(tester, _phone);
    await pumpAntgrid(
      tester,
      SizedBox(
        width: 360,
        child: AbListRow(
          title: const Text('row'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbIconButton(icon: AbIcons.trash, onTap: () {}),
              AbChip.toggle(label: 'on', selected: true, onTap: () {}),
              AbButton(label: 'Go', onTap: () {}),
            ],
          ),
        ),
      ),
    );
    final icon = tester.getSize(find.byType(AbIconButton));
    expect(icon.width, AbTokens.touchControlMin);
    expect(icon.height, lessThan(AbTokens.touchControlMin));
    expect(
      tester.getSize(find.byType(AbChip)).height,
      lessThan(AbTokens.touchControlMin),
    );
    expect(
      tester.getSize(find.byType(AbButton)).height,
      lessThan(AbTokens.touchControlMin),
    );
    expect(
      tester.getSize(find.byType(AbListRow)).height,
      lessThan(AbTokens.touchControlMin),
    );
  }, variant: _android);

  testWidgets('a toolbar keeps its controls at desktop proportions', (
    tester,
  ) async {
    _sizeView(tester, _phone);
    late double extent;
    await pumpAntgrid(
      tester,
      SizedBox(
        width: 360,
        child: AbToolbar.actions(
          leading: [
            Builder(
              builder: (context) {
                extent = AbTouchSizing.extentOf(context);
                return AbButton(label: 'Run', onTap: () {});
              },
            ),
          ],
        ),
      ),
    );
    expect(extent, 0);
    expect(
      tester.getSize(find.byType(AbButton)).height,
      lessThan(AbTokens.rowHeightSm),
    );
  }, variant: _android);

  testWidgets('a footprint width matches the width the button lays out', (
    tester,
  ) async {
    _sizeView(tester, _phone);
    late double declared;
    await pumpAntgrid(
      tester,
      Builder(
        builder: (context) {
          declared = AbIconButton.footprintWidth(context);
          return AbIconButton(icon: AbIcons.close, onTap: () {});
        },
      ),
    );
    expect(tester.getSize(find.byType(AbIconButton)).width, declared);
    expect(declared, AbTokens.touchControlMin);
  }, variant: _android);

  testWidgets('live menu rows match static menu rows', (tester) async {
    _sizeView(tester, _phone);
    await pumpAntgrid(
      tester,
      SizedBox(
        width: 240,
        child: AbLiveMenuRow(label: 'Arm Handler', onTap: () {}),
      ),
    );
    expect(
      tester.getSize(find.byType(AbLiveMenuRow)).height,
      greaterThanOrEqualTo(AbTokens.touchControlMin),
    );
  }, variant: _android);
}
