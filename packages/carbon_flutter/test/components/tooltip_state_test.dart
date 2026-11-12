import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const String _tip = 'Saves every open file';

/// Counts mounts so a test can tell a rebuild from a remount.
class _Probe extends StatefulWidget {
  const _Probe();

  static int inits = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.inits++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 80, height: 40);
}

Future<void> _mouseHover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(1, 1));
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
}

void main() {
  setUp(() => _Probe.inits = 0);
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('toggling enabled or clearing the message keeps the child', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    Widget tip({bool enabled = true, String message = _tip}) => Center(
      child: CarbonTooltip(
        message: message,
        enabled: enabled,
        child: Focus(focusNode: node, child: const _Probe()),
      ),
    );
    await pumpCarbon(tester, tip());
    node.requestFocus();
    await tester.pump();
    expect(_Probe.inits, 1);
    expect(node.hasFocus, isTrue);

    await pumpCarbon(tester, tip(enabled: false));
    await pumpCarbon(tester, tip(message: ''));
    await pumpCarbon(tester, tip());
    expect(_Probe.inits, 1);
    expect(node.hasFocus, isTrue);
  });

  testWidgets('a composite child keeps its controls separately reachable', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: _tip,
          mergeChildSemantics: false,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CarbonButton(label: 'Alpha', onPressed: () {}),
              CarbonButton(label: 'Beta', onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    final a = tester.getSemantics(find.text('Alpha'));
    final b = tester.getSemantics(find.text('Beta'));
    expect(a.id, isNot(b.id));
    expect(a.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(b.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });

  testWidgets('a single control still carries the tooltip', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: _tip,
          child: CarbonButton(label: 'Save', onPressed: () {}),
        ),
      ),
    );
    final data = tester.getSemantics(find.text('Save')).getSemanticsData();
    expect(data.tooltip, _tip);
    expect(data.label, contains('Save'));
    handle.dispose();
  });

  testWidgets('excludeFromSemantics drops the tooltip string only', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: _tip,
          excludeFromSemantics: true,
          child: CarbonButton(label: 'Save', onPressed: () {}),
        ),
      ),
    );
    final data = tester.getSemantics(find.text('Save')).getSemanticsData();
    expect(data.tooltip, isEmpty);
    expect(data.label, contains('Save'));
    handle.dispose();
  });

  testWidgets('the long press is not advertised to assistive technology', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: _tip,
          child: CarbonButton(label: 'Save', onPressed: () {}),
        ),
      ),
    );
    final data = tester.getSemantics(find.text('Save')).getSemanticsData();
    expect(data.hasAction(SemanticsAction.longPress), isFalse);
    handle.dispose();
  });

  testWidgets('a mouse click that focuses the child does not show the tip', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic;
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: _tip,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: node.requestFocus,
            child: Focus(
              focusNode: node,
              child: const SizedBox(
                key: Key('target'),
                width: 120,
                height: 40,
              ),
            ),
          ),
        ),
      ),
    );
    final target = find.byKey(const Key('target'));
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(node.hasPrimaryFocus, isTrue);
    expect(find.text(_tip), findsNothing);
  });

  testWidgets('a tooltip around an icon-only button shows one tooltip', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: 'Outer',
          child: CarbonButton.iconOnly(
            icon: const CarbonIcon(CarbonIcons.settings),
            semanticLabel: 'Inner',
            onPressed: () {},
          ),
        ),
      ),
    );
    await _mouseHover(tester, find.byType(CarbonButton));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Outer'), findsOneWidget);
    expect(find.text('Inner'), findsNothing);
  });

  testWidgets('the message reads at body size with 16px padding', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      Center(
        child: CarbonTooltip(
          message: _tip,
          child: CarbonButton(label: 'Save', onPressed: () {}),
        ),
      ),
    );
    await _mouseHover(tester, find.byType(CarbonButton));
    await tester.pump(const Duration(milliseconds: 300));
    final text = tester.widget<Text>(find.text(_tip));
    expect(text.style!.fontSize, 14);
    final padding = tester.widget<Padding>(
      find.ancestor(of: find.text(_tip), matching: find.byType(Padding)).first,
    );
    expect(padding.padding, const EdgeInsets.all(16));
  });
}
