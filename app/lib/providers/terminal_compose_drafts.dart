import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The touch terminal's prompt-box drafts, keyed by terminal, outliving the
/// terminal view that edits them. A reconnect swaps the agent pane for its
/// "waiting for agent" placeholder and mounts a fresh view when the terminal
/// comes back, so a draft held in the view's own State was lost to every
/// network blip.
///
/// Plain strings rather than controllers: nothing listens across views, so
/// there is no lifetime to manage and no controller to dispose under an
/// editor that is still tearing down.
class TerminalComposeDrafts {
  final _text = <String, String>{};
  final _open = <String>{};

  static String keyFor({
    required String projectId,
    required String checkoutId,
    required String terminalId,
  }) => '$projectId\u0000$checkoutId\u0000$terminalId';

  String textFor(String key) => _text[key] ?? '';

  bool isOpen(String key) => _open.contains(key);

  /// Empty text drops the entry, so a sent or cleared draft leaves nothing
  /// behind for a terminal that may never come back.
  void save(String key, {required String text, required bool open}) {
    if (text.isEmpty) {
      _text.remove(key);
    } else {
      _text[key] = text;
    }
    if (open) {
      _open.add(key);
    } else {
      _open.remove(key);
    }
  }

  void clear() {
    _text.clear();
    _open.clear();
  }
}

final terminalComposeDraftsProvider = Provider<TerminalComposeDrafts>((ref) {
  final drafts = TerminalComposeDrafts();
  ref.onDispose(drafts.clear);
  return drafts;
});
