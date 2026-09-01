// Pins what the pinned `ghostty_vte_flutter` engine does to already-written
// rows when the column count changes.
//
// Load-bearing because `_TerminalGridFreeze` (terminal_view_wrapper.dart) rests
// entirely on the second half of that contract. The engine re-wraps rows IT
// soft-wrapped, so reflow alone would make a grid resize harmless — but a row
// the guest broke itself is a hard break no reflow can re-join, and an
// Ink-style TUI wraps its own output, so every row it writes is in that second
// class. That is why a grid resized underneath one leaks stale fragments and
// why the pin exists. A failure in the first test means the engine stopped
// reflowing; a failure in the second means the freeze's rationale went with it.
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

/// True when the native VT is missing, having marked the current test skipped.
///
/// Skipped rather than quietly returned from: a bare early return makes a host
/// with no prebuilt libghostty-vt report a green suite that asserted nothing.
bool _skipWithoutNative() {
  if (_hasNative()) return false;
  markTestSkipped('native VT unavailable');
  return true;
}

bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a soft-wrapped row re-wraps when the grid widens', () {
    if (_skipWithoutNative()) return;
    final c = GhosttyTerminalController();
    addTearDown(c.dispose);
    c.attachExternalTransport(writeBytes: (_) => true);
    c.resize(cols: 40, rows: 10);

    // 60 printable chars with no newline: the engine soft-wraps it at 40.
    final text = List.generate(
      60,
      (i) => String.fromCharCode(97 + i % 26),
    ).join();
    c.appendOutputBytes(text.codeUnits);

    final narrow = c.lines.where((l) => l.trim().isNotEmpty).toList();
    expect(narrow.length, 2, reason: 'soft-wrapped into two rows at 40 cols');

    c.resize(cols: 80, rows: 10);
    final wide = c.lines.where((l) => l.trim().isNotEmpty).toList();
    printOnFailure('narrow: $narrow\nwide: $wide');

    expect(
      wide.length,
      1,
      reason: 'the engine reflows the primary screen when the grid widens',
    );
    expect(wide.single.trimRight(), text);
  });

  test('a HARD-wrapped row does not re-join when the grid widens', () {
    if (_skipWithoutNative()) return;
    final c = GhosttyTerminalController();
    addTearDown(c.dispose);
    c.attachExternalTransport(writeBytes: (_) => true);
    c.resize(cols: 40, rows: 10);

    // What an Ink-style TUI emits: it wraps its own output AT the margin and
    // writes the break itself. Each row is exactly `cols` wide, so it is
    // indistinguishable from a soft wrap by width alone — the engine has to be
    // tracking the wrap flag to keep them apart, which is the whole contract.
    // Rows narrower than the margin would pass this test against an engine with
    // no wrap tracking at all.
    final a = 'a' * 40;
    final b = 'b' * 40;
    c.appendOutputBytes('$a\r\n$b'.codeUnits);

    final narrow = c.lines.where((l) => l.trim().isNotEmpty).toList();
    expect(narrow.length, 2, reason: 'two margin-filling rows at 40 cols');

    c.resize(cols: 80, rows: 10);
    final wide = c.lines.where((l) => l.trim().isNotEmpty).toList();
    printOnFailure('narrow: $narrow\nwide: $wide');

    expect(wide.length, 2, reason: 'a self-written break is never re-joined');
    expect(wide.first.trimRight(), a);
  });
}
