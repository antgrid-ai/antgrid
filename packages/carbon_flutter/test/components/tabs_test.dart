import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _abc = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Beta'),
  CarbonOption(value: 'c', label: 'Gamma'),
];

const _withDisabled = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Beta', enabled: false),
  CarbonOption(value: 'c', label: 'Gamma'),
];

bool _focused(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

/// Stateful host so selection follows the callbacks like a real screen.
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.tabs,
    this.initial = 'a',
    this.activation = CarbonActivationMode.automatic,
    this.variant = CarbonTabsVariant.line,
    this.log,
  });

  final List<CarbonOption<String>> tabs;
  final String initial;
  final CarbonActivationMode activation;
  final CarbonTabsVariant variant;
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
        CarbonTabs<String>(
          tabs: widget.tabs,
          value: value,
          variant: widget.variant,
          activation: widget.activation,
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

void _noop() {}

Finder _selectedSemantics(String label) => find.text(label);

void main() {
  group('sizing and layout', () {
    testWidgets('height is 40 compact and 48 touch', (tester) async {
      final harness = await pumpCarbon(tester, const _Host(tabs: _abc));
      final tab = find.ancestor(
        of: find.text('Alpha'),
        matching: find.byType(ConstrainedBox),
      );
      expect(tab, findsWidgets);
      expect(tester.getSize(find.text('Alpha')).height, lessThan(40));
      Size tabSize() => tester.getSize(
        find
            .ancestor(
              of: find.text('Beta'),
              matching: find.byType(CarbonFocusRing),
            )
            .first,
      );
      expect(tabSize().height, 40);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tabSize().height, 48);
      await harness.setDensity(tester, CarbonDensity.compact);
      expect(tabSize().height, 40);
    });

    testWidgets('grows at 200% text and keeps tabs the same height', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(tabs: _abc),
        textScale: 2,
        size: const Size(800, 600),
      );
      final heights = [
        for (final l in ['Alpha', 'Beta', 'Gamma'])
          tester
              .getSize(
                find
                    .ancestor(
                      of: find.text(l),
                      matching: find.byType(CarbonFocusRing),
                    )
                    .first,
              )
              .height,
      ];
      expect(heights.toSet().length, 1);
      expect(heights.first, greaterThan(40));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a label wider than the list wraps instead of overflowing', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(
          tabs: [
            CarbonOption(
              value: 'a',
              label: 'A very long tab label that cannot fit in a narrow list',
            ),
            CarbonOption(value: 'b', label: 'Beta'),
          ],
        ),
        size: const Size(200, 600),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final box = tester.getRect(find.byType(CarbonTabs<String>));
      expect(box.width, lessThanOrEqualTo(200));
    });

    testWidgets('contained variant paints and selects', (tester) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        _Host(
          tabs: _abc,
          variant: CarbonTabsVariant.contained,
          log: log,
        ),
      );
      await tester.tap(find.text('Gamma'));
      await tester.pump();
      expect(log, ['c']);
    });

    testWidgets('icons show before the label', (tester) async {
      await pumpCarbon(
        tester,
        CarbonTabs<String>(
          tabs: const [
            CarbonOption(
              value: 'a',
              label: 'Settings',
              icon: CarbonIcon(CarbonIcons.settings),
            ),
          ],
          value: 'a',
          onChanged: (_) {},
        ),
      );
      expect(find.byType(CarbonIcon), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(CarbonIcon)).dx,
        lessThan(tester.getTopLeft(find.text('Settings')).dx),
      );
    });
  });

  group('selection', () {
    testWidgets('tap selects and the selected tab is not re-reported', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(tabs: _abc, log: log));
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      expect(log, isEmpty);
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(log, ['b']);
    });

    testWidgets('a disabled tab never activates', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(tabs: _withDisabled, log: log));
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('semantics: tab role, label and selected state', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(tabs: _abc));
      expect(
        tester.getSemantics(_selectedSemantics('Alpha')),
        isSemantics(label: 'Alpha', isSelected: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(_selectedSemantics('Beta')),
        isSemantics(label: 'Beta', isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('selected value that matches no tab selects nothing', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(tabs: _abc, initial: 'zzz'));
      expect(
        tester.getSemantics(find.text('Alpha')),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });
  });

  group('keyboard', () {
    testWidgets('the list is a single tab stop', (tester) async {
      await pumpCarbon(tester, const _Host(tabs: _abc));
      await _focus(tester, 'Before');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'After'), isTrue);
      await _shiftTab(tester);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
    });

    testWidgets('tab enters on the selected tab', (tester) async {
      await pumpCarbon(tester, const _Host(tabs: _abc, initial: 'c'));
      await _focus(tester, 'Before');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'Gamma'), isTrue);
    });

    testWidgets('arrows move and select in automatic mode, wrapping', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(tabs: _abc, log: log));
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Beta'), isTrue);
      expect(log, ['b']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
      expect(log, ['b', 'c', 'a']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focused(tester, 'Gamma'), isTrue);
    });

    testWidgets('Home and End jump to the ends', (tester) async {
      await pumpCarbon(tester, const _Host(tabs: _abc, initial: 'b'));
      await tester.tap(find.text('Beta'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(_focused(tester, 'Gamma'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
    });

    testWidgets('right-to-left mirrors the arrow keys', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(tabs: _abc),
        dir: TextDirection.rtl,
      );
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      // Alpha is the rightmost tab; the next tab is to its left.
      expect(
        tester.getCenter(find.text('Beta')).dx,
        lessThan(tester.getCenter(find.text('Alpha')).dx),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focused(tester, 'Beta'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
    });

    testWidgets('disabled tabs are skipped by arrows, Home and End', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(tabs: _withDisabled, log: log));
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Gamma'), isTrue);
      expect(log, ['c']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(_focused(tester, 'Gamma'), isTrue);
    });

    testWidgets('manual mode moves focus without changing selection', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        _Host(tabs: _abc, activation: CarbonActivationMode.manual, log: log),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'Beta'), isTrue);
      expect(log, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(log, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(log, ['c']);
    });

    testWidgets('manual mode: Space selects the focused tab', (tester) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        _Host(tabs: _abc, activation: CarbonActivationMode.manual, log: log),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log, ['b']);
    });

    testWidgets('manual mode: tab stop returns to the selected tab', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(tabs: _abc, activation: CarbonActivationMode.manual),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      // Leave the list and come back: focus lands on the selected tab, not
      // the one that merely held focus.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'After'), isTrue);
      await _shiftTab(tester);
      await tester.pump();
      expect(_focused(tester, 'Alpha'), isTrue);
    });

    testWidgets('ctrl+arrow is left to the host', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(tabs: _abc, log: log));
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(log, isEmpty);
    });
  });

  group('overflow', () {
    final many = <CarbonOption<String>>[
      for (var i = 0; i < 12; i++)
        CarbonOption(value: 'tab$i', label: 'Tab number $i'),
    ];

    testWidgets('no scroll buttons when the tabs fit', (tester) async {
      await pumpCarbon(tester, const _Host(tabs: _abc));
      await tester.pump();
      expect(find.byType(CarbonIcon), findsNothing);
    });

    testWidgets('scroll buttons appear when tabs overflow and scroll', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab0'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('Scroll back'), findsOneWidget);
      expect(find.bySemanticsLabel('Scroll forward'), findsOneWidget);
      final before = tester.getTopLeft(find.text('Tab number 0')).dx;
      await tester.tap(find.bySemanticsLabel('Scroll forward'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Tab number 0')).dx, lessThan(before));
      await tester.tap(find.bySemanticsLabel('Scroll back'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Tab number 0')).dx, before);
      handle.dispose();
    });

    testWidgets('scroll buttons are not tab stops', (tester) async {
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab0'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      await _focus(tester, 'Before');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'Tab number 0'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, 'After'), isTrue);
    });

    testWidgets('end key scrolls the last tab into view', (tester) async {
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab0'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Tab number 0'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      final right = tester.getRect(find.text('Tab number 11')).right;
      expect(right, lessThanOrEqualTo(400));
      expect(_focused(tester, 'Tab number 11'), isTrue);
    });

    testWidgets('an initially selected far tab starts in view', (tester) async {
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab11'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('Tab number 11'));
      expect(rect.right, lessThanOrEqualTo(400));
      expect(rect.left, greaterThanOrEqualTo(0));
    });

    testWidgets('right-to-left overflow scrolls the focused tab into view', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab0'),
        size: const Size(400, 400),
        dir: TextDirection.rtl,
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Tab number 0'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('Tab number 11'));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(400));
    });

    testWidgets('buttons disappear when the tabs stop overflowing', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab0'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(CarbonIcon), findsNWidgets(2));
      await pumpCarbon(
        tester,
        _Host(tabs: many, initial: 'tab0'),
        size: const Size(3000, 400),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(CarbonIcon), findsNothing);
    });
  });

  group('lifecycle', () {
    testWidgets('tabs added and removed keep focus state consistent', (
      tester,
    ) async {
      final tabs = ValueNotifier<List<CarbonOption<String>>>(_abc);
      addTearDown(tabs.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<List<CarbonOption<String>>>(
          valueListenable: tabs,
          builder: (context, value, _) =>
              _Host(key: ValueKey(value.length), tabs: value),
        ),
      );
      tabs.value = const [CarbonOption(value: 'a', label: 'Alpha')];
      await tester.pump();
      await tester.pump();
      expect(find.text('Beta'), findsNothing);
      tabs.value = _abc;
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing the focused tab does not throw', (tester) async {
      final tabs = ValueNotifier<List<CarbonOption<String>>>(_abc);
      addTearDown(tabs.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<List<CarbonOption<String>>>(
          valueListenable: tabs,
          builder: (context, value, _) => CarbonTabs<String>(
            tabs: value,
            value: 'a',
            onChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('Gamma'));
      await tester.pump();
      tabs.value = const [
        CarbonOption(value: 'a', label: 'Alpha'),
        CarbonOption(value: 'b', label: 'Beta'),
      ];
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('theme and density changes keep focus and selection', (
      tester,
    ) async {
      final harness = await pumpCarbon(tester, const _Host(tabs: _abc));
      await tester.tap(find.text('Beta'));
      await tester.pump();
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(_focused(tester, 'Beta'), isTrue);
      await setCarbonTheme(
        tester,
        CarbonThemeData(scheme: CarbonThemeScheme.gray100),
      );
      expect(_focused(tester, 'Beta'), isTrue);
    });
  });

  group('CarbonTabPanels', () {
    testWidgets('only the selected pane is visible and the rest are inert', (
      tester,
    ) async {
      final value = ValueNotifier<String>('a');
      addTearDown(value.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<String>(
          valueListenable: value,
          builder: (context, v, _) => CarbonTabPanels<String>(
            value: v,
            panels: const [
              CarbonTabPanel(
                value: 'a',
                child: CarbonButton(label: 'In A', onPressed: _noop),
              ),
              CarbonTabPanel(
                value: 'b',
                child: CarbonButton(label: 'In B', onPressed: _noop),
              ),
            ],
          ),
        ),
      );
      expect(find.text('In A'), findsOneWidget);
      // Pane B has never been shown, so it is not built yet.
      expect(find.text('In B', skipOffstage: false), findsNothing);
      value.value = 'b';
      await tester.pump();
      expect(find.text('In B'), findsOneWidget);
      expect(find.text('In A'), findsNothing);
      // A is retained, offstage.
      expect(find.text('In A', skipOffstage: false), findsOneWidget);
    });

    testWidgets('hidden panes mute tickers and cannot take focus', (
      tester,
    ) async {
      final value = ValueNotifier<String>('a');
      addTearDown(value.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<String>(
          valueListenable: value,
          builder: (context, v, _) => CarbonTabPanels<String>(
            value: v,
            panels: const [
              CarbonTabPanel(value: 'a', child: CarbonSpinner()),
              CarbonTabPanel(
                value: 'b',
                child: CarbonButton(label: 'In B', onPressed: _noop),
              ),
            ],
          ),
        ),
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      value.value = 'b';
      await tester.pump();
      value.value = 'a';
      await tester.pump();
      value.value = 'b';
      await tester.pump();
      // Spinner A is hidden now: no ticker runs.
      expect(tester.binding.transientCallbackCount, 0);
      value.value = 'a';
      await tester.pump();
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      // The hidden B button is unreachable by focus traversal.
      final bButton = find.text('In B', skipOffstage: false);
      final node = Focus.of(tester.element(bButton));
      expect(node.canRequestFocus, isFalse);
    });

    testWidgets('state survives switching away and back', (tester) async {
      final value = ValueNotifier<String>('a');
      addTearDown(value.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<String>(
          valueListenable: value,
          builder: (context, v, _) => CarbonTabPanels<String>(
            value: v,
            panels: [
              const CarbonTabPanel(value: 'a', child: _Counter()),
              const CarbonTabPanel(value: 'b', child: SizedBox()),
            ],
          ),
        ),
      );
      await tester.tap(find.byType(_Counter));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      value.value = 'b';
      await tester.pump();
      value.value = 'a';
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('keepAlive false discards hidden panes', (tester) async {
      final value = ValueNotifier<String>('a');
      addTearDown(value.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<String>(
          valueListenable: value,
          builder: (context, v, _) => CarbonTabPanels<String>(
            value: v,
            keepAlive: false,
            panels: const [
              CarbonTabPanel(value: 'a', child: Text('pane a')),
              CarbonTabPanel(value: 'b', child: Text('pane b')),
            ],
          ),
        ),
      );
      value.value = 'b';
      await tester.pump();
      expect(find.text('pane a', skipOffstage: false), findsNothing);
      expect(find.text('pane b'), findsOneWidget);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => count++),
      child: Text('$count'),
    );
  }
}

Future<void> _shiftTab(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

Future<void> _focus(WidgetTester tester, String label) async {
  Focus.of(tester.element(find.text(label))).requestFocus();
  await tester.pump();
}
