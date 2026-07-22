import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/transcript/composer/smart_enter.dart';

void main() {
  group('decideEnter', () {
    ({bool plain, bool shift, bool ctrl, bool hw}) c({
      bool plain = true,
      bool shift = false,
      bool ctrl = false,
      bool hw = true,
    }) => (plain: plain, shift: shift, ctrl: ctrl, hw: hw);

    final cases = <({bool plain, bool shift, bool ctrl, bool hw}), EnterAction>{
      // Plain paragraph: Enter sends.
      c(): EnterAction.send,
      // Shift+Enter is always a newline.
      c(shift: true): EnterAction.fallthrough,
      // Ctrl/Cmd+Enter always sends, even on a formatted line.
      c(ctrl: true): EnterAction.send,
      c(plain: false, ctrl: true): EnterAction.send,
      // Any formatted line (list/code/quote/heading): plain Enter continues it
      // instead of sending.
      c(plain: false): EnterAction.fallthrough,
      // Shift wins over context the same way (still fallthrough).
      c(plain: false, shift: true): EnterAction.fallthrough,
      // Ctrl beats Shift: explicit send intent wins.
      c(shift: true, ctrl: true): EnterAction.send,
      // No hardware keyboard: never send from Enter.
      c(hw: false): EnterAction.fallthrough,
      c(plain: false, hw: false): EnterAction.fallthrough,
      c(ctrl: true, hw: false): EnterAction.fallthrough,
    };

    cases.forEach((input, expected) {
      test('plain=${input.plain} shift=${input.shift} ctrl=${input.ctrl} '
          'hw=${input.hw} -> $expected', () {
        expect(
          decideEnter(
            caretLineIsPlain: input.plain,
            isShift: input.shift,
            isCtrlOrCmd: input.ctrl,
            hasHardwareKeyboard: input.hw,
          ),
          expected,
        );
      });
    });
  });
}
