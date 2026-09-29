import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/terminal_modifier_keys.dart';

void main() {
  const ctrl = TerminalModifiers(ctrl: true);
  const alt = TerminalModifiers(alt: true);
  const shift = TerminalModifiers(shift: true);

  test('Ctrl maps letters and punctuation to C0 bytes', () {
    expect(applyTerminalModifiers('c', ctrl), '\x03');
    expect(applyTerminalModifiers('C', ctrl), '\x03');
    expect(applyTerminalModifiers('[', ctrl), '\x1b');
    expect(applyTerminalModifiers(' ', ctrl), '\x00');
  });

  test('Alt prefixes ESC; Shift upper-cases', () {
    expect(applyTerminalModifiers('b', alt), '\x1bb');
    expect(applyTerminalModifiers('a', shift), 'A');
    expect(
      applyTerminalModifiers('x', const TerminalModifiers(ctrl: true, alt: true)),
      '\x1b\x18',
    );
  });

  test('arrows carry the xterm modifier parameter', () {
    expect(applyTerminalModifiers('\x1b[A', shift), '\x1b[1;2A');
    expect(applyTerminalModifiers('\x1b[D', ctrl), '\x1b[1;5D');
    expect(applyTerminalModifiers('\x1b[C', alt), '\x1b[1;3C');
  });

  test('Shift+Tab is back-tab; Shift/Alt+Enter is ESC CR', () {
    expect(applyTerminalModifiers('\t', shift), '\x1b[Z');
    expect(applyTerminalModifiers('\r', shift), '\x1b\r');
    expect(applyTerminalModifiers('\r', alt), '\x1b\r');
    expect(applyTerminalModifiers('\r', ctrl), '\r');
  });

  // A phone keyboard auto-capitalises; the chord must not care.
  test('Ctrl and Alt ignore the letter case unless Shift is armed', () {
    expect(applyTerminalModifiers('C', ctrl), applyTerminalModifiers('c', ctrl));
    expect(applyTerminalModifiers('C', alt), '\x1bc');
    expect(applyTerminalModifiers('c', alt), '\x1bc');
    expect(
      applyTerminalModifiers('c', const TerminalModifiers(alt: true, shift: true)),
      '\x1bC',
    );
  });

  test('multi-character text is not a keystroke', () {
    expect(applyTerminalModifiers('hello', ctrl), isNull);
  });

  test('the latch is spent by one keystroke and kept through a paste', () {
    final latch = TerminalModifierLatch()..toggle(TerminalModifierKey.ctrl);
    expect(latch.apply('pasted text'), 'pasted text');
    expect(latch.value.ctrl, isTrue);
    expect(latch.apply('c'), '\x03');
    expect(latch.value.isEmpty, isTrue);
    expect(latch.apply('c'), 'c');
  });
}
