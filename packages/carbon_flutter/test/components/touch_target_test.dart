import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const List<CarbonOption<String>> _options = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Bravo'),
];

CarbonThemeData _touch(double target) =>
    CarbonThemeData(density: CarbonDensity.touch, touchTarget: target);

Widget _aligned(Widget child) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: 320, child: child),
);

Finder _interactionOf(String label) => find
    .ancestor(of: find.text(label), matching: find.byType(CarbonInteraction))
    .first;

/// Every family that sizes itself from the touch extent, measured once with
/// Carbon's generic 48 and once with a host-chosen 44.
void main() {
  test('touchTarget defaults to 48 and flows through theme data', () {
    expect(CarbonThemeData().touchTarget, 48);
    expect(
      CarbonThemeData.forBrightness(
        Brightness.light,
        touchTarget: 44,
      ).touchTarget,
      44,
    );
    final t = _touch(44);
    expect(t.copyWith(density: CarbonDensity.compact).touchTarget, 44);
    expect(t.copyWith(touchTarget: 40).touchTarget, 40);
    expect(t, isNot(_touch(48)));
    expect(t.hashCode, _touch(44).hashCode);
    expect(t.controlHeight, 44);
    expect(t.smallControlHeight, 44);
    expect(t.minTarget, 44);
    expect(t.largeControlHeight, 64);
  });

  test('compact density ignores touchTarget', () {
    final t = CarbonThemeData(touchTarget: 44);
    expect(t.controlHeight, 32);
    expect(t.smallControlHeight, 24);
    expect(t.minTarget, 32);
  });

  for (final target in <double>[48, 44]) {
    group('touch target $target', () {
      testWidgets('button and icon-only button', (tester) async {
        await pumpCarbon(
          tester,
          _aligned(
            Row(
              children: [
                CarbonButton(label: 'Save', onPressed: () {}),
                CarbonButton.iconOnly(
                  icon: const CarbonIcon(CarbonIcons.close),
                  semanticLabel: 'Close',
                  onPressed: () {},
                ),
              ],
            ),
          ),
          theme: _touch(target),
        );
        expect(tester.getSize(find.byType(CarbonButton).first).height, target);
        expect(
          tester.getSize(find.byType(CarbonButton).last),
          Size(target, target),
        );
      });

      testWidgets('text input and its action', (tester) async {
        await pumpCarbon(
          tester,
          _aligned(const CarbonTextInput(label: 'Name', clearable: true)),
          theme: _touch(target),
        );
        expect(tester.getSize(find.byType(CarbonFieldBox)).height, target);
        await tester.enterText(find.byType(EditableText), 'x');
        await tester.pump();
        expect(
          tester.getSize(find.byType(CarbonFieldAction)),
          Size(target, target),
        );
      });

      testWidgets('select field and rows', (tester) async {
        await pumpCarbon(
          tester,
          _aligned(
            CarbonSelect<String>(
              label: 'Mode',
              options: _options,
              value: 'a',
              onChanged: (_) {},
            ),
          ),
          theme: _touch(target),
          size: const Size(800, 600),
        );
        expect(tester.getSize(find.byType(CarbonFieldBox)).height, target);
        await tester.tap(find.byType(CarbonFieldBox));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final row = tester.getRect(
          find
              .ancestor(
                of: find.text('Bravo'),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(row.height, target);
      });

      testWidgets('combo box field', (tester) async {
        await pumpCarbon(
          tester,
          _aligned(
            CarbonComboBox<String>(
              label: 'Project',
              options: _options,
              value: 'a',
              onChanged: (_) {},
            ),
          ),
          theme: _touch(target),
        );
        expect(tester.getSize(find.byType(CarbonFieldBox)).height, target);
      });

      testWidgets('checkbox and toggle targets', (tester) async {
        await pumpCarbon(
          tester,
          _aligned(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CarbonCheckbox(
                  key: const Key('cb'),
                  value: true,
                  onChanged: (_) {},
                ),
                CarbonToggle(
                  key: const Key('tg'),
                  value: true,
                  onChanged: (_) {},
                  semanticLabel: 'Auto-save',
                ),
              ],
            ),
          ),
          theme: _touch(target),
        );
        expect(tester.getSize(find.byKey(const Key('cb'))).height, target);
        expect(tester.getSize(find.byKey(const Key('tg'))).height, target);
      });

      testWidgets('tabs and content switcher', (tester) async {
        await pumpCarbon(
          tester,
          _aligned(
            Column(
              children: [
                CarbonTabs<String>(
                  tabs: _options,
                  value: 'a',
                  onChanged: (_) {},
                ),
                CarbonContentSwitcher<String>(
                  options: _options,
                  value: 'a',
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
          theme: _touch(target),
        );
        final tab = find
            .ancestor(
              of: find.text('Bravo'),
              matching: find.byType(CarbonFocusRing),
            )
            .first;
        expect(tester.getSize(tab).height, target);
        expect(
          tester.getSize(find.byType(CarbonContentSwitcher<String>)).height,
          target,
        );
      });

      testWidgets('menu items', (tester) async {
        final controller = CarbonPopupController();
        addTearDown(controller.dispose);
        await pumpCarbon(
          tester,
          _aligned(
            CarbonMenu(
              controller: controller,
              entries: <CarbonMenuEntry>[
                CarbonMenuItem(label: 'Copy', onPressed: () {}),
              ],
              child: CarbonButton(
                label: 'Trigger',
                onPressed: controller.toggle,
              ),
            ),
          ),
          theme: _touch(target),
          size: const Size(800, 600),
        );
        await tester.tap(find.text('Trigger'));
        await tester.pump();
        await tester.pump();
        expect(tester.getSize(_interactionOf('Copy')).height, target);
      });

      testWidgets('modal close button and action footer', (tester) async {
        final key = GlobalKey();
        await pumpCarbon(
          tester,
          SizedBox(key: key),
          theme: _touch(target),
          size: const Size(800, 600),
        );
        showCarbonModal<void>(
          key.currentContext!,
          builder: (context) => CarbonModal(
            title: 'Rename',
            body: const Text('Name'),
            actions: [
              CarbonModalAction(label: 'Cancel', onPressed: () {}),
              CarbonModalAction(label: 'Save', onPressed: () {}),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final close = find.byWidgetPredicate(
          (w) => w is CarbonButton && w.label == null,
        );
        expect(tester.getSize(close), Size(target, target));
        final save = find.byWidgetPredicate(
          (w) => w is CarbonButton && w.label == 'Save',
        );
        expect(tester.getSize(save).height, 64);
      });

      testWidgets('side nav link, menu and nested item', (tester) async {
        await pumpCarbon(
          tester,
          Align(
            alignment: AlignmentDirectional.topStart,
            child: CarbonSideNav(
              width: 288,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  CarbonSideNavLink(label: 'Link', onPressed: () {}),
                  CarbonSideNavLink(label: 'Large', large: true, onPressed: () {}),
                  CarbonSideNavMenu(
                    title: 'Menu',
                    expanded: true,
                    onExpandedChanged: (_) {},
                    children: [
                      CarbonSideNavLink(label: 'Nested', onPressed: () {}),
                    ],
                  ),
                ],
              ),
            ),
          ),
          theme: _touch(target),
          size: const Size(800, 600),
        );
        Size size(String label) =>
            tester.getSize(find.widgetWithText(CarbonSideNavLink, label));
        expect(size('Link').height, target);
        expect(size('Nested').height, target);
        // Large is 48 where that clears the finger target, and never less.
        expect(size('Large').height, target > 48 ? target : 48);
        expect(
          tester
              .getSize(find.widgetWithText(CarbonSideNavMenu, 'Menu'))
              .height,
          greaterThanOrEqualTo(target + target),
        );
      });
    });
  }
}
