import 'dart:ui' show CheckedState, SemanticsAction, Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _target = Key('target');

Widget _button({
  VoidCallback? onPressed,
  FocusNode? focusNode,
  bool autofocus = false,
  bool focusableWhenDisabled = false,
  VoidCallback? onLongPress,
  VoidCallback? onSecondaryTap,
  ValueChanged<CarbonInteractionState>? onState,
  ValueChanged<bool>? onFocusChange,
  ValueChanged<bool>? onHoverChange,
  bool requestFocusOnTap = false,
  String label = 'Save',
}) {
  return Center(
    child: CarbonInteraction(
      key: _target,
      onPressed: onPressed,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      focusNode: focusNode,
      autofocus: autofocus,
      focusableWhenDisabled: focusableWhenDisabled,
      onFocusChange: onFocusChange,
      onHoverChange: onHoverChange,
      requestFocusOnTap: requestFocusOnTap,
      label: label,
      excludeChildSemantics: true,
      builder: (context, state, child) {
        onState?.call(state);
        return CarbonFocusRing(
          visible: state.focusVisible,
          child: SizedBox(width: 120, height: 32, child: child),
        );
      },
      child: Text(label),
    ),
  );
}

void main() {
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('tap activates once', (tester) async {
    var count = 0;
    await pumpCarbon(tester, _button(onPressed: () => count++));
    await tester.tap(find.byKey(_target));
    await tester.pump();
    expect(count, 1);
  });

  testWidgets('Enter, NumpadEnter and Space activate when focused', (
    tester,
  ) async {
    var count = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(
      tester,
      _button(onPressed: () => count++, focusNode: node),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(count, 3);
  });

  testWidgets('holding a key does not repeat activation', (tester) async {
    var count = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(
      tester,
      _button(onPressed: () => count++, focusNode: node),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(count, 1);
  });

  testWidgets('disabled is inert and cannot take focus', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    CarbonInteractionState? last;
    await pumpCarbon(
      tester,
      _button(focusNode: node, onState: (s) => last = s),
    );
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isFalse);
    await tester.tap(find.byKey(_target), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(last!.enabled, isFalse);
    expect(last!.pressed, isFalse);

    final semantics = tester.getSemantics(find.byKey(_target));
    expect(
      semantics,
      matchesSemantics(
        label: 'Save',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        isFocusable: false,
      ),
    );
  });

  testWidgets('enabled semantics expose button, label and tap', (
    tester,
  ) async {
    await pumpCarbon(tester, _button(onPressed: () {}));
    expect(
      tester.getSemantics(find.byKey(_target)),
      matchesSemantics(
        label: 'Save',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
  });

  testWidgets('checked, mixed, toggled, selected and expanded flags', (
    tester,
  ) async {
    Widget row({bool? checked, bool mixed = false}) => Center(
      child: CarbonInteraction(
        key: _target,
        onPressed: () {},
        button: false,
        checked: checked,
        mixed: mixed,
        selected: true,
        expanded: false,
        label: 'Row',
        builder: (_, _, _) => const SizedBox(width: 40, height: 32),
      ),
    );
    await pumpCarbon(tester, row(checked: true));
    var data = tester.getSemantics(find.byKey(_target)).getSemanticsData();
    expect(data.flagsCollection.isChecked, CheckedState.isTrue);
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    expect(data.flagsCollection.isExpanded, Tristate.isFalse);
    expect(data.flagsCollection.isButton, isFalse);

    await pumpCarbon(tester, row(checked: true, mixed: true));
    data = tester.getSemantics(find.byKey(_target)).getSemanticsData();
    expect(data.flagsCollection.isChecked, CheckedState.mixed);
  });

  testWidgets('pointer cancel never activates and clears pressed', (
    tester,
  ) async {
    var count = 0;
    CarbonInteractionState? last;
    await pumpCarbon(
      tester,
      _button(onPressed: () => count++, onState: (s) => last = s),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_target)),
    );
    await tester.pump();
    expect(last!.pressed, isTrue);
    await gesture.cancel();
    await tester.pump();
    expect(last!.pressed, isFalse);
    expect(count, 0);
  });

  testWidgets('dragging off the control does not activate', (tester) async {
    var count = 0;
    await pumpCarbon(tester, _button(onPressed: () => count++));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_target)),
    );
    await gesture.moveBy(const Offset(0, 200));
    await gesture.up();
    await tester.pump();
    expect(count, 0);
  });

  testWidgets('becoming disabled drops hover and pressed', (tester) async {
    CarbonInteractionState? last;
    var enabled = true;
    late StateSetter setOuter;
    await pumpCarbon(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return _button(
            onPressed: enabled ? () {} : null,
            onState: (s) => last = s,
          );
        },
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byKey(_target)));
    await tester.pump();
    expect(last!.hovered, isTrue);
    final press = await tester.startGesture(
      tester.getCenter(find.byKey(_target)),
    );
    await tester.pump();
    expect(last!.pressed, isTrue);

    setOuter(() => enabled = false);
    await tester.pump();
    expect(last!.hovered, isFalse);
    expect(last!.pressed, isFalse);
    await press.up();
    await tester.pump();
  });

  testWidgets('mouse cursor is click when enabled, basic when disabled', (
    tester,
  ) async {
    await pumpCarbon(tester, _button(onPressed: () {}));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byKey(_target)));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await pumpCarbon(tester, _button());
    await mouse.moveBy(const Offset(1, 0));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
  });

  testWidgets('long press and secondary tap reach their callbacks', (
    tester,
  ) async {
    var pressed = 0;
    var long = 0;
    var secondary = 0;
    await pumpCarbon(
      tester,
      _button(
        onPressed: () => pressed++,
        onLongPress: () => long++,
        onSecondaryTap: () => secondary++,
      ),
    );
    await tester.longPress(find.byKey(_target));
    await tester.pump();
    await tester.tap(find.byKey(_target), buttons: kSecondaryButton);
    await tester.pump();
    expect(long, 1);
    expect(secondary, 1);
    expect(pressed, 0);
  });

  testWidgets('focusVisible follows keyboard highlight mode only', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    CarbonInteractionState? last;
    await pumpCarbon(
      tester,
      _button(onPressed: () {}, focusNode: node, onState: (s) => last = s),
    );
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    node.requestFocus();
    await tester.pump();
    expect(last!.focused, isTrue);
    expect(last!.focusVisible, isFalse);
    expect(_ringPainted(tester), isFalse);

    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.pump();
    expect(last!.focusVisible, isTrue);
    expect(_ringPainted(tester), isTrue);

    node.unfocus();
    await tester.pump();
    await tester.pump();
    expect(last!.focused, isFalse);
    expect(last!.focusVisible, isFalse);
    expect(_ringPainted(tester), isFalse);
  });

  testWidgets('focusableWhenDisabled keeps focus but never activates', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    var count = 0;
    var enabled = true;
    late StateSetter setOuter;
    await pumpCarbon(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return _button(
            onPressed: enabled ? () => count++ : null,
            focusNode: node,
            focusableWhenDisabled: true,
          );
        },
      ),
    );
    node.requestFocus();
    await tester.pump();
    setOuter(() => enabled = false);
    await tester.pump();
    expect(node.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(find.byKey(_target));
    await tester.pump();
    expect(count, 0);
  });

  testWidgets('supplied focus node swaps keep working and are not disposed', (
    tester,
  ) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    var count = 0;
    await pumpCarbon(tester, _button(onPressed: () => count++, focusNode: a));
    a.requestFocus();
    await tester.pump();
    expect(a.hasFocus, isTrue);

    await pumpCarbon(tester, _button(onPressed: () => count++, focusNode: b));
    b.requestFocus();
    await tester.pump();
    expect(b.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(count, 1);

    // Back to an owned node, then to a supplied one again.
    await pumpCarbon(tester, _button(onPressed: () => count++));
    await pumpCarbon(tester, _button(onPressed: () => count++, focusNode: a));
    a.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(count, 2);

    // Unmounting must leave caller-owned nodes usable.
    await pumpCarbon(tester, const SizedBox());
    expect(() => a.addListener(() {}), returnsNormally);
  });

  testWidgets('swapping the focus node while focused keeps focus truthful', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final events = <bool>[];
    CarbonInteractionState? last;
    Widget build(FocusNode node) => _button(
      onPressed: () {},
      focusNode: node,
      onFocusChange: events.add,
      onState: (s) => last = s,
    );
    await pumpCarbon(tester, build(a));
    a.requestFocus();
    await tester.pump();
    expect(last!.focused, isTrue);

    await pumpCarbon(tester, build(b));
    await tester.pump();
    expect(last!.focused, isFalse);
    expect(events, <bool>[true, false]);

    b.requestFocus();
    // The focus change lands in a microtask after this pump's frame.
    await tester.pump();
    await tester.pump();
    expect(b.hasFocus, isTrue);
    expect(last!.focused, isTrue);
    expect(last!.focusVisible, isTrue);
    expect(_ringPainted(tester), isTrue);
    expect(events, <bool>[true, false, true]);

    b.unfocus();
    await tester.pump();
    await tester.pump();
    expect(last!.focused, isFalse);
    expect(events, <bool>[true, false, true, false]);
  });

  testWidgets('disabling while hovered reports hover loss outside build', (
    tester,
  ) async {
    final busy = ValueNotifier<bool>(false);
    addTearDown(busy.dispose);
    final events = <bool>[];
    await pumpCarbon(
      tester,
      _HoverHost(
        onHover: events.add,
        child: (onHoverChange) => ValueListenableBuilder<bool>(
          valueListenable: busy,
          builder: (context, isBusy, _) => _button(
            onPressed: isBusy ? null : () {},
            onHoverChange: onHoverChange,
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byKey(_target)));
    await tester.pump();
    expect(find.text('hovered'), findsOneWidget);

    busy.value = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
    expect(events, <bool>[true, false]);
  });

  testWidgets('semantics tap takes focus like a pointer tap', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    var count = 0;
    await pumpCarbon(
      tester,
      _button(
        onPressed: () => count++,
        focusNode: node,
        requestFocusOnTap: true,
      ),
    );
    final semantics = tester.getSemantics(find.byKey(_target));
    semantics.owner!.performAction(semantics.id, SemanticsAction.tap);
    await tester.pump();
    expect(count, 1);
    expect(node.hasFocus, isTrue);
  });

  testWidgets('repeated mount and unmount does not throw', (tester) async {
    for (var i = 0; i < 5; i++) {
      await pumpCarbon(tester, _button(onPressed: () {}, autofocus: true));
      await tester.pump();
      await pumpCarbon(tester, const SizedBox());
    }
    expect(tester.takeException(), isNull);
  });
}

bool _ringPainted(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(CarbonFocusRing),
      matching: find.byType(CustomPaint),
    ),
  );
  return paint.foregroundPainter != null;
}

/// Tracks hover in its own state, above the widget that disables the control,
/// as a host revealing secondary actions on hover would.
class _HoverHost extends StatefulWidget {
  const _HoverHost({required this.onHover, required this.child});

  final ValueChanged<bool> onHover;
  final Widget Function(ValueChanged<bool> onHoverChange) child;

  @override
  State<_HoverHost> createState() => _HoverHostState();
}

class _HoverHostState extends State<_HoverHost> {
  bool _hovered = false;

  void _handleHover(bool value) {
    widget.onHover(value);
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(_hovered ? 'hovered' : 'idle'),
        Expanded(child: widget.child(_handleHover)),
      ],
    );
  }
}
