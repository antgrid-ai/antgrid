import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _three = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'First'),
  CarbonOption(value: 'b', label: 'Second'),
  CarbonOption(value: 'c', label: 'Third'),
];

const _withDisabled = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'First'),
  CarbonOption(value: 'b', label: 'Second', enabled: false),
  CarbonOption(value: 'c', label: 'Third'),
];

void _noop() {}

bool _focused(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

Future<void> _shiftTab(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

class _Host extends StatefulWidget {
  const _Host({
    required this.options,
    this.initial = 'a',
    this.activation = CarbonActivationMode.automatic,
    this.size = CarbonContentSwitcherSize.medium,
    this.iconOnly = false,
    this.expand = false,
    this.log,
  });

  final List<CarbonOption<String>> options;
  final String initial;
  final CarbonActivationMode activation;
  final CarbonContentSwitcherSize size;
  final bool iconOnly;
  final bool expand;
  final List<String>? log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String value = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CarbonButton(label: 'Before', onPressed: _noop),
        CarbonContentSwitcher<String>(
          options: widget.options,
          value: value,
          size: widget.size,
          iconOnly: widget.iconOnly,
          activation: widget.activation,
          expand: widget.expand,
          onChanged: (v) {
            widget.log?.add(v);
            setState(() => value = v);
          },
        ),
        const CarbonButton(label: 'After', onPressed: _noop),
      ],
    );
  }
}

Finder _segment(String label) => find
    .ancestor(of: find.text(label), matching: find.byType(CarbonFocusRing))
    .first;

void main() {
  group('sizing', () {
    testWidgets('compact heights follow the size, touch is always 48', (
      tester,
    ) async {
      final heights = <CarbonContentSwitcherSize, double>{};
      for (final size in CarbonContentSwitcherSize.values) {
        await tester.pumpWidget(const SizedBox());
        await pumpCarbon(tester, _Host(options: _three, size: size));
        heights[size] = tester.getSize(_segment('First')).height;
      }
      expect(heights, {
        CarbonContentSwitcherSize.small: 32.0,
        CarbonContentSwitcherSize.medium: 40.0,
        CarbonContentSwitcherSize.large: 48.0,
      });
      final harness = await pumpCarbon(
        tester,
        const _Host(options: _three, size: CarbonContentSwitcherSize.small),
      );
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(_segment('First')).height, 48);
    });

    testWidgets('segments share one width', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(
          options: [
            CarbonOption(value: 'a', label: 'A'),
            CarbonOption(value: 'b', label: 'A much longer label'),
          ],
        ),
      );
      expect(
        tester.getSize(_segment('A')).width,
        tester.getSize(_segment('A much longer label')).width,
      );
    });

    testWidgets('expand fills the available width', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(options: _three, expand: true),
        size: const Size(500, 300),
      );
      final box = tester.getRect(find.byType(CarbonContentSwitcher<String>));
      expect(box.width, 500);
    });

    testWidgets('wraps and grows instead of overflowing at 200% text', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(
          options: [
            CarbonOption(value: 'a', label: 'Terminal output'),
            CarbonOption(value: 'b', label: 'Changed files'),
            CarbonOption(value: 'c', label: 'Browser preview'),
          ],
        ),
        size: const Size(320, 600),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final heights = {
        for (final l in ['Terminal output', 'Changed files', 'Browser preview'])
          tester.getSize(_segment(l)).height,
      };
      expect(heights.length, 1);
      expect(heights.first, greaterThan(40));
      expect(
        tester.getRect(find.byType(CarbonContentSwitcher<String>)).right,
        lessThanOrEqualTo(320),
      );
    });

    testWidgets('right-to-left lays segments out from the right', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(options: _three),
        dir: TextDirection.rtl,
      );
      expect(
        tester.getCenter(find.text('Second')).dx,
        lessThan(tester.getCenter(find.text('First')).dx),
      );
    });
  });

  group('selection', () {
    testWidgets('exactly one option is selected after every change', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(options: _three));
      int selectedCount() => [
        for (final l in ['First', 'Second', 'Third'])
          isSemantics(isSelected: true).matches(
            tester.getSemantics(find.text(l)),
            <dynamic, dynamic>{},
          ),
      ].where((s) => s).length;
      expect(selectedCount(), 1);
      await tester.tap(find.text('Third'));
      await tester.pump();
      expect(selectedCount(), 1);
      expect(
        tester.getSemantics(find.text('Third')),
        isSemantics(isSelected: true),
      );
      await tester.tap(find.text('First'));
      await tester.pump();
      expect(selectedCount(), 1);
      handle.dispose();
    });

    testWidgets('re-selecting the selected option does nothing', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(options: _three, log: log));
      await tester.tap(find.text('First'));
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('a disabled option never activates', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(options: _withDisabled, log: log));
      await tester.tap(find.text('Second'));
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('semantics expose tab role, name, selected and disabled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(options: _withDisabled));
      expect(
        tester.getSemantics(find.text('First')),
        isSemantics(label: 'First', isSelected: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.text('Second')),
        isSemantics(label: 'Second', isSelected: false, isEnabled: false),
      );
      handle.dispose();
    });

    testWidgets('icon-only options are named by their labels', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        const _Host(
          iconOnly: true,
          options: [
            CarbonOption(
              value: 'a',
              label: 'List view',
              icon: CarbonIcon(CarbonIcons.view),
            ),
            CarbonOption(
              value: 'b',
              label: 'Settings',
              icon: CarbonIcon(CarbonIcons.settings),
            ),
          ],
        ),
      );
      expect(find.text('List view'), findsNothing);
      expect(find.byType(CarbonIcon), findsNWidgets(2));
      expect(find.bySemanticsLabel('List view'), findsOneWidget);
      expect(find.bySemanticsLabel('Settings'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('icon-only segments are at least square', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(
          iconOnly: true,
          options: [
            CarbonOption(
              value: 'a',
              label: 'List view',
              icon: CarbonIcon(CarbonIcons.view),
            ),
            CarbonOption(
              value: 'b',
              label: 'Settings',
              icon: CarbonIcon(CarbonIcons.settings),
            ),
          ],
        ),
      );
      final box = tester.getSize(
        find.byType(CarbonFocusRing).first,
      );
      expect(box.width, greaterThanOrEqualTo(box.height));
    });

    testWidgets('icon plus text shows both', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(
          options: [
            CarbonOption(
              value: 'a',
              label: 'List',
              icon: CarbonIcon(CarbonIcons.view),
            ),
            CarbonOption(value: 'b', label: 'Other'),
          ],
        ),
      );
      expect(find.text('List'), findsOneWidget);
      expect(find.byType(CarbonIcon), findsOneWidget);
    });
  });

  group('keyboard', () {
    testWidgets('one tab stop, entering on the selected option', (
      tester,
    ) async {
      await pumpCarbon(tester, const _Host(options: _three, initial: 'b'));
      await _focus(tester, 'Before');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'Second'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'After'), isTrue);
      await _shiftTab(tester);
      expect(_focused(tester, 'Second'), isTrue);
    });

    testWidgets('arrows move and select in automatic mode and wrap', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(options: _three, log: log));
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Second'), isTrue);
      expect(log, ['b']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focused(tester, 'Third'), isTrue);
      expect(log, ['b', 'a', 'c']);
    });

    testWidgets('Home and End', (tester) async {
      await pumpCarbon(tester, const _Host(options: _three, initial: 'b'));
      await tester.tap(find.text('Second'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(_focused(tester, 'Third'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(_focused(tester, 'First'), isTrue);
    });

    testWidgets('right-to-left mirrors the arrows', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(options: _three),
        dir: TextDirection.rtl,
      );
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focused(tester, 'Second'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'First'), isTrue);
    });

    testWidgets('disabled options are skipped', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(options: _withDisabled, log: log));
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Third'), isTrue);
      expect(log, ['c']);
    });

    testWidgets('manual mode keeps selection while focus moves', (tester) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        _Host(
          options: _three,
          activation: CarbonActivationMode.manual,
          log: log,
        ),
      );
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(_focused(tester, 'Third'), isTrue);
      expect(log, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log, ['c']);
    });

    testWidgets('selection style differs from focus: focus alone never selects', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        const _Host(options: _three, activation: CarbonActivationMode.manual),
      );
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        tester.getSemantics(find.text('Second')),
        isSemantics(isSelected: false, isFocused: true),
      );
      expect(
        tester.getSemantics(find.text('First')),
        isSemantics(isSelected: true),
      );
      handle.dispose();
    });
  });

  group('lifecycle', () {
    testWidgets('option list change keeps working and does not throw', (
      tester,
    ) async {
      final options = ValueNotifier<List<CarbonOption<String>>>(_three);
      addTearDown(options.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<List<CarbonOption<String>>>(
          valueListenable: options,
          builder: (context, value, _) => CarbonContentSwitcher<String>(
            options: value,
            value: 'a',
            onChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('Third'));
      await tester.pump();
      options.value = const [
        CarbonOption(value: 'a', label: 'First'),
        CarbonOption(value: 'b', label: 'Second'),
      ];
      await tester.pump();
      await tester.pump();
      expect(find.text('Third'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('theme change keeps focus', (tester) async {
      final harness = await pumpCarbon(tester, const _Host(options: _three));
      await tester.tap(find.text('Second'));
      await tester.pump();
      await harness.setTheme(
        tester,
        CarbonThemeData(
          scheme: CarbonThemeScheme.gray100,
          density: CarbonDensity.touch,
        ),
      );
      expect(_focused(tester, 'Second'), isTrue);
    });
  });
}

Future<void> _focus(WidgetTester tester, String label) async {
  Focus.of(tester.element(find.text(label))).requestFocus();
  await tester.pump();
}
