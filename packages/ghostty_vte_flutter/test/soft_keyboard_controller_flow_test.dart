// Repro for the button-driven soft-keyboard flow the app uses on mobile:
// `showKeyboardOnInteraction: false` + `GhosttyTerminalSoftKeyboardController`.
// Locks in that IME deltas (insertions AND deletions) still reach the
// transport when the keyboard is summoned via the controller instead of
// focus-gain.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'support/native_terminal.dart';

final bool _hasNativeTerminal = hasNativeTerminal;

final _android = TargetPlatformVariant.only(TargetPlatform.android);

Future<void> _sendDeltas(
  WidgetTester tester,
  List<Map<String, dynamic>> deltas,
) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    MethodCall('TextInputClient.updateEditingStateWithDeltas', <dynamic>[
      -1,
      <String, dynamic>{'deltas': deltas},
    ]),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/textinput',
    message,
    (ByteData? _) {},
  );
  await tester.pump();
}

Map<String, dynamic> _encodeDelta({
  required String oldText,
  required String deltaText,
  required int deltaStart,
  required int deltaEnd,
  required int selection,
  int composingBase = -1,
  int composingExtent = -1,
}) => <String, dynamic>{
  'oldText': oldText,
  'deltaText': deltaText,
  'deltaStart': deltaStart,
  'deltaEnd': deltaEnd,
  'selectionBase': selection,
  'selectionExtent': selection,
  'selectionAffinity': 'TextAffinity.downstream',
  'selectionIsDirectional': false,
  'composingBase': composingBase,
  'composingExtent': composingExtent,
};

// Must mirror _GhosttyTerminalSoftKeyboard._seedLength / _seedRune.
const int _seedLength = 64;
final String _seed = String.fromCharCode(0x200b) * _seedLength;

void main() {
  late GhosttyTerminalController controller;
  final captured = <int>[];

  setUp(() {
    captured.clear();
    controller = GhosttyTerminalController();
    if (_hasNativeTerminal) {
      controller.attachExternalTransport(
        writeBytes: (bytes) {
          captured.addAll(bytes);
          return true;
        },
      );
    }
  });

  tearDown(() {
    controller.dispose();
  });

  Widget buildView(
    FocusNode focusNode,
    GhosttyTerminalSoftKeyboardController softKeyboard,
  ) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 600,
        height: 400,
        child: GhosttyTerminalView(
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          showKeyboardOnInteraction: false,
          softKeyboardController: softKeyboard,
        ),
      ),
    ),
  );

  testWidgets('focus gain does NOT attach the IME when suppressed', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final softKeyboard = GhosttyTerminalSoftKeyboardController();
    await tester.pumpWidget(buildView(focusNode, softKeyboard));
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isFalse);
  }, variant: _android);

  testWidgets('controller.show() attaches; deletion delta sends backspace', (
    tester,
  ) async {
    if (!_hasNativeTerminal) {
      return;
    }
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final softKeyboard = GhosttyTerminalSoftKeyboardController();
    await tester.pumpWidget(buildView(focusNode, softKeyboard));
    await tester.pump();

    softKeyboard.show();
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);

    captured.clear();
    await _sendDeltas(tester, [
      _encodeDelta(
        oldText: _seed,
        deltaText: '',
        deltaStart: _seed.length - 1,
        deltaEnd: _seed.length,
        selection: _seed.length - 1,
      ),
    ]);

    final backspaces = captured.where((b) => b == 0x7f || b == 0x08).length;
    expect(backspaces, 1, reason: 'deletion delta must yield one backspace');
  }, variant: _android);

  testWidgets('controller.toggle() raises then dismisses the keyboard', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final softKeyboard = GhosttyTerminalSoftKeyboardController();
    await tester.pumpWidget(buildView(focusNode, softKeyboard));
    await tester.pump();

    // Suppressed focus-gain: down until the button asks for it.
    expect(softKeyboard.isVisible, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);

    softKeyboard.toggle(); // down -> up
    await tester.pump();
    expect(softKeyboard.isVisible, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    softKeyboard.toggle(); // up -> down (second press dismisses)
    await tester.pump();
    expect(softKeyboard.isVisible, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);
  }, variant: _android);

  testWidgets(
    'controller.show() before focus lands still yields working backspace',
    (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final softKeyboard = GhosttyTerminalSoftKeyboardController();
      await tester.pumpWidget(buildView(focusNode, softKeyboard));
      await tester.pump();

      // Simulate the wrapper's Keyboard button: terminal blurred first.
      focusNode.unfocus();
      await tester.pump();
      softKeyboard.show(); // requestFocus + attach in one call
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(focusNode.hasFocus, isTrue);

      captured.clear();
      await _sendDeltas(tester, [
        _encodeDelta(
          oldText: _seed,
          deltaText: '',
          deltaStart: _seed.length - 1,
          deltaEnd: _seed.length,
          selection: _seed.length - 1,
        ),
      ]);

      final backspaces = captured.where((b) => b == 0x7f || b == 0x08).length;
      expect(backspaces, 1);
    },
    variant: _android,
  );

  testWidgets(
    'backspace KeyEvent is handled by the raw path while IME attached',
    (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final softKeyboard = GhosttyTerminalSoftKeyboardController();
      await tester.pumpWidget(buildView(focusNode, softKeyboard));
      await tester.pump();

      softKeyboard.show();
      await tester.pump();

      captured.clear();
      // IMEs commonly send backspace as a bare KEYCODE_DEL key event; the
      // engine's editable fallback drops it, so the raw path must handle it
      // even while the IME connection is attached.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      final backspaces = captured.where((b) => b == 0x7f || b == 0x08).length;
      expect(backspaces, 1);
    },
    variant: _android,
  );

  testWidgets(
    'hardware backspace works when IME was never summoned (suppressed mode)',
    (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final softKeyboard = GhosttyTerminalSoftKeyboardController();
      await tester.pumpWidget(buildView(focusNode, softKeyboard));
      await tester.pump();

      expect(tester.testTextInput.hasAnyClients, isFalse);

      captured.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      final backspaces = captured.where((b) => b == 0x7f || b == 0x08).length;
      expect(backspaces, 1);
    },
    variant: _android,
  );
}
