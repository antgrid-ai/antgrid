import 'package:flutter/foundation.dart';

/// The one-shot modifiers armed on the touch key bar. A soft keyboard has no
/// Ctrl or Alt of its own, so the bar holds them for the NEXT keystroke —
/// whether that comes from the bar or from the IME — and then lets go.
@immutable
class TerminalModifiers {
  const TerminalModifiers({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  static const none = TerminalModifiers();

  final bool ctrl;
  final bool alt;
  final bool shift;

  bool get isEmpty => !ctrl && !alt && !shift;

  /// xterm's modifier parameter: 1 + Shift(1) + Alt(2) + Ctrl(4).
  int get _xtermParam => 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);

  TerminalModifiers copyWith({bool? ctrl, bool? alt, bool? shift}) =>
      TerminalModifiers(
        ctrl: ctrl ?? this.ctrl,
        alt: alt ?? this.alt,
        shift: shift ?? this.shift,
      );

  @override
  bool operator ==(Object other) =>
      other is TerminalModifiers &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(ctrl, alt, shift);
}

enum TerminalModifierKey { ctrl, alt, shift }

/// Holds the armed modifiers between a bar tap and the keystroke they apply to.
class TerminalModifierLatch extends ValueNotifier<TerminalModifiers> {
  TerminalModifierLatch() : super(TerminalModifiers.none);

  void toggle(TerminalModifierKey key) {
    final m = value;
    value = switch (key) {
      TerminalModifierKey.ctrl => m.copyWith(ctrl: !m.ctrl),
      TerminalModifierKey.alt => m.copyWith(alt: !m.alt),
      TerminalModifierKey.shift => m.copyWith(shift: !m.shift),
    };
  }

  void clear() => value = TerminalModifiers.none;

  /// Applies and releases the armed modifiers when [data] is a single
  /// keystroke. Anything longer (a paste, a sent capture) passes through
  /// untouched and leaves the latch armed: a modifier the user meant for their
  /// next key must not be spent on text they did not type.
  String apply(String data) {
    final m = value;
    if (m.isEmpty) return data;
    final out = applyTerminalModifiers(data, m);
    if (out == null) return data;
    clear();
    return out;
  }
}

final RegExp _csiArrowOrNav = RegExp(r'^\x1b\[([ABCDHF])$');

/// Encodes one keystroke [data] under [m], the way xterm would have sent the
/// chord from a physical keyboard. Null when [data] is not a single keystroke.
@visibleForTesting
String? applyTerminalModifiers(String data, TerminalModifiers m) {
  if (data.isEmpty) return null;

  final csi = _csiArrowOrNav.firstMatch(data);
  if (csi != null) return '\x1b[1;${m._xtermParam}${csi.group(1)}';

  if (data == '\t') {
    if (m.shift && !m.ctrl) return m.alt ? '\x1b\x1b[Z' : '\x1b[Z';
    return m.alt ? '\x1b\t' : '\t';
  }

  if (data == '\r') {
    // ESC CR is what agent CLIs (Claude Code, Codex) read as "newline without
    // submitting" — the chord a desktop user reaches with Shift/Alt+Enter.
    if (m.shift || m.alt) return '\x1b\r';
    return '\r';
  }

  if (data == '\x1b') return '\x1b';

  if (data.runes.length != 1) return null;
  var code = data.runes.first;
  if (code < 0x20 && code != 0x7f) {
    // Already a control byte: only Alt adds anything.
    return m.alt ? '\x1b$data' : data;
  }

  var char = String.fromCharCode(code);
  if (m.shift) {
    char = char.toUpperCase();
    code = char.runes.first;
  } else if (m.ctrl || m.alt) {
    // A chord names a KEY, not a case: a phone keyboard auto-capitalises the
    // first letter it types, and Alt+C would otherwise send ESC C where the
    // user meant ESC c. Only an armed Shift asks for the capital.
    char = char.toLowerCase();
    code = char.runes.first;
  }
  if (m.ctrl) {
    final ctrl = _ctrlByte(code);
    if (ctrl != null) char = String.fromCharCode(ctrl);
  }
  return m.alt ? '\x1b$char' : char;
}

/// The C0 byte Ctrl turns [code] into, or null where the chord has none.
int? _ctrlByte(int code) {
  if (code >= 0x61 && code <= 0x7a) return code - 0x60; // a-z
  if (code >= 0x40 && code <= 0x5f) return code - 0x40; // @ A-Z [ \ ] ^ _
  if (code == 0x20 || code == 0x32) return 0x00; // Ctrl+Space, Ctrl+2
  if (code == 0x3f) return 0x7f; // Ctrl+?
  return null;
}
