import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/semantics.dart';
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
  _tabExtensionTests();
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

    testWidgets('icons show after the label', (tester) async {
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
        greaterThan(tester.getTopLeft(find.text('Settings')).dx),
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
      // Carbon hides a button while there is nothing to scroll that way.
      expect(find.bySemanticsLabel('Scroll back'), findsNothing);
      expect(find.bySemanticsLabel('Scroll forward'), findsOneWidget);
      final before = tester.getTopLeft(find.text('Tab number 0')).dx;
      await tester.tap(find.bySemanticsLabel('Scroll forward'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Scroll back'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Tab number 0')).dx, lessThan(before));
      // The viewport is narrower while the back button shows, so a page back
      // can stop short of the start; the button hides once it gets there.
      for (var i = 0; i < 3 && find.bySemanticsLabel('Scroll back').evaluate().isNotEmpty; i++) {
        await tester.tap(find.bySemanticsLabel('Scroll back'));
        await tester.pumpAndSettle();
      }
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
      expect(find.byType(CarbonIcon), findsNWidgets(1));
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

class _CloseHost extends StatefulWidget {
  const _CloseHost({
    required this.tabs,
    required this.closed,
    this.selected,
    this.variant = CarbonTabsVariant.line,
    this.closeLabelBuilder,
  });

  final List<CarbonOption<String>> tabs;
  final List<String> closed;
  final List<String>? selected;
  final CarbonTabsVariant variant;
  final String Function(String name)? closeLabelBuilder;

  @override
  State<_CloseHost> createState() => _CloseHostState();
}

class _CloseHostState extends State<_CloseHost> {
  String value = 'a';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarbonTabs<String>(
          tabs: widget.tabs,
          value: value,
          variant: widget.variant,
          activation: CarbonActivationMode.manual,
          onChanged: (v) {
            widget.selected?.add(v);
            setState(() => value = v);
          },
          onClose: widget.closed.add,
          closeLabelBuilder: widget.closeLabelBuilder,
        ),
      ],
    );
  }
}

Finder _closeTarget() => find
    .ancestor(
      of: find.byType(CarbonIcon).first,
      matching: find.byType(CarbonInteraction),
    )
    .first;

void _tabExtensionTests() {
  group('semantic label, leading and secondary label', () {
    testWidgets('a tab is spoken as semanticLabel, falling back to label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        const _Host(
          tabs: [
            CarbonOption(
              value: 'a',
              label: 'Git',
              semanticLabel: 'Git changes',
            ),
            CarbonOption(value: 'b', label: 'Files'),
          ],
        ),
      );
      expect(
        tester.getSemantics(find.text('Git')),
        isSemantics(label: 'Git changes', isSelected: true),
      );
      expect(
        tester.getSemantics(find.text('Files')),
        isSemantics(label: 'Files', isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('leading sits before the label', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(
          tabs: [
            CarbonOption(
              value: 'a',
              label: 'Alpha',
              leading: SizedBox(key: Key('dot'), width: 8, height: 8),
            ),
          ],
        ),
      );
      final dot = tester.getRect(find.byKey(const Key('dot')));
      final label = tester.getRect(find.text('Alpha'));
      expect(dot.right, lessThanOrEqualTo(label.left));
      expect(dot.center.dy, closeTo(label.center.dy, 1));
    });

    testWidgets('a line tab shows the secondary label after the name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        const _Host(
          tabs: [CarbonOption(value: 'a', label: 'Git', secondaryLabel: '3')],
        ),
      );
      final name = tester.getRect(find.text('Git'));
      final count = tester.getRect(find.text('3'));
      expect(count.left, greaterThanOrEqualTo(name.right));
      expect(count.center.dy, closeTo(name.center.dy, 1));
      expect(
        tester.getSemantics(find.text('Git')),
        isSemantics(label: 'Git, 3', isSelected: true),
      );
      handle.dispose();
    });

    testWidgets('a contained tab stacks the secondary label under the name', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(
          variant: CarbonTabsVariant.contained,
          tabs: [CarbonOption(value: 'a', label: 'Git', secondaryLabel: '3')],
        ),
      );
      expect(
        tester.getRect(find.text('3')).top,
        greaterThanOrEqualTo(tester.getRect(find.text('Git')).bottom),
      );
    });
  });

  group('dismissible', () {
    testWidgets('pressing the close glyph closes without selecting', (
      tester,
    ) async {
      final closed = <String>[];
      final selected = <String>[];
      await pumpCarbon(
        tester,
        _CloseHost(tabs: _abc, closed: closed, selected: selected),
      );
      // One glyph per tab in order; the second belongs to Beta.
      await tester.tap(find.byType(CarbonIcon).at(1));
      await tester.pump();
      expect(closed, ['b']);
      expect(selected, isEmpty);
    });

    testWidgets('Delete closes the focused tab and does not select it', (
      tester,
    ) async {
      final closed = <String>[];
      final selected = <String>[];
      await pumpCarbon(
        tester,
        _CloseHost(tabs: _abc, closed: closed, selected: selected),
      );
      await _focus(tester, 'Beta');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(closed, ['b']);
      expect(selected, isEmpty);
    });

    testWidgets('a disabled tab shows an inert close glyph', (tester) async {
      final closed = <String>[];
      await pumpCarbon(tester, _CloseHost(tabs: _withDisabled, closed: closed));
      expect(find.byType(CarbonIcon), findsNWidgets(_withDisabled.length));
      await tester.tap(find.byType(CarbonIcon).at(1), warnIfMissed: false);
      await tester.pump();
      expect(closed, isEmpty);
    });

    testWidgets('a slow press on the glyph neither focuses nor outlines the tab', (
      tester,
    ) async {
      await pumpCarbon(tester, _CloseHost(tabs: _abc, closed: <String>[]));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CarbonIcon).first),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final tabContext = tester.element(find.text('Alpha'));
      expect(Focus.of(tabContext).hasFocus, isFalse);
      for (final ring in tester.widgetList<CarbonFocusRing>(
        find.byType(CarbonFocusRing),
      )) {
        expect(ring.visible, isFalse);
      }
      await gesture.up();
      await tester.pump();
    });

    testWidgets('Delete does nothing without onClose', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(tabs: _abc, log: log));
      await _focus(tester, 'Beta');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(log, isEmpty);
      expect(find.byType(CarbonIcon), findsNothing);
    });

    testWidgets('the tab offers Close name as an action', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _CloseHost(
          tabs: const [
            CarbonOption(
              value: 'a',
              label: 'Git',
              semanticLabel: 'Git changes',
            ),
          ],
          closed: <String>[],
        ),
      );
      expect(_closeActions(tester, 'Git'), ['Close Git changes']);
      handle.dispose();
    });

    testWidgets('closeLabelBuilder overrides the action name', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _CloseHost(
          tabs: _abc,
          closed: <String>[],
          closeLabelBuilder: (n) => 'Dismiss $n',
        ),
      );
      expect(_closeActions(tester, 'Alpha'), ['Dismiss Alpha']);
      handle.dispose();
    });

    testWidgets('the close action on the tab closes it', (tester) async {
      final handle = tester.ensureSemantics();
      final closed = <String>[];
      final selected = <String>[];
      await pumpCarbon(
        tester,
        _CloseHost(tabs: _abc, closed: closed, selected: selected),
      );
      final node = tester.getSemantics(find.text('Beta'));
      final id = node.getSemanticsData().customSemanticsActionIds!.single;
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
      await tester.pump();
      expect(closed, ['b']);
      expect(selected, isEmpty);
      handle.dispose();
    });

    for (final variant in CarbonTabsVariant.values) {
      testWidgets('close target meets the touch floor in ${variant.name}', (
        tester,
      ) async {
        final harness = await pumpCarbon(
          tester,
          _CloseHost(tabs: _abc, closed: <String>[], variant: variant),
        );
        Size tabSize() => tester.getSize(
          find
              .ancestor(
                of: find.text('Alpha'),
                matching: find.byType(CarbonFocusRing),
              )
              .first,
        );
        expect(tester.getSize(_closeTarget()).width, greaterThanOrEqualTo(32));
        expect(tabSize().height, 40);
        await harness.setDensity(tester, CarbonDensity.touch);
        final target = tester.getSize(_closeTarget());
        expect(target.width, greaterThanOrEqualTo(48));
        expect(target.height, greaterThanOrEqualTo(48));
        expect(tabSize().height, 48);
      });
    }
  });
}

List<String> _closeActions(WidgetTester tester, String tabText) {
  final data = tester.getSemantics(find.text(tabText)).getSemanticsData();
  return [
    for (final id in data.customSemanticsActionIds ?? const <int>[])
      CustomSemanticsAction.getAction(id)!.label!,
  ];
}
