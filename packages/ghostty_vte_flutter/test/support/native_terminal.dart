import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

/// Whether the native Ghostty VT engine is loadable in this test environment.
///
/// On hosts without the prebuilt native asset (or unsupported platforms),
/// `GhosttyVt.newTerminal` throws; native-only tests gate on this and return
/// early instead of failing. Shared single source of truth — previously this
/// was copy-pasted into every native-terminal test file.
final bool hasNativeTerminal = _detectNativeTerminal();

bool _detectNativeTerminal() {
  try {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    terminal.close();
    return true;
  } catch (_) {
    return false;
  }
}
