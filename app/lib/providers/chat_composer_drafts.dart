import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/transcript/composer/composer_controller.dart';

/// In-memory chat drafts keyed by session. Navigation can remount a transcript,
/// but a session mutation must release the controller once that session is gone.
class ChatComposerDrafts {
  final _controllers = <String, ComposerController>{};

  /// Sessions whose transcript is on screen right now, counted because a keyed
  /// remount builds the incoming State before the outgoing one is disposed.
  final _holders = <String, int>{};

  /// Retired while still on screen — see [remove].
  final _retired = <String, ComposerController>{};

  ComposerController forSession(String sessionId) {
    _holders.update(sessionId, (n) => n + 1, ifAbsent: () => 1);
    return _controllers.putIfAbsent(sessionId, ComposerController.new);
  }

  /// The transcript for [sessionId] has unmounted and no longer reads the
  /// controller. Paired with [forSession]; call it from `dispose`, never
  /// instead of it, because a draft must survive an ordinary remount.
  void release(String sessionId) {
    final holders = (_holders[sessionId] ?? 1) - 1;
    if (holders > 0) {
      _holders[sessionId] = holders;
      return;
    }
    _holders.remove(sessionId);
    _retired.remove(sessionId)?.dispose();
  }

  void remove(String sessionId) {
    final controller = _controllers.remove(sessionId);
    if (controller == null) return;
    // The delete/archive RPC returns before the state push that unmounts the
    // transcript, so the editor for the session being retired is routinely
    // still on screen and still listening. Disposing the controller under it
    // throws "used after being disposed" out of the editor's own teardown —
    // hand it to [release] instead.
    if (_holders.containsKey(sessionId)) {
      _retired[sessionId] = controller;
      return;
    }
    controller.dispose();
  }

  void clear() {
    for (final sessionId in _controllers.keys.toList()) {
      remove(sessionId);
    }
  }
}

final chatComposerDraftsProvider = Provider<ChatComposerDrafts>((ref) {
  final drafts = ChatComposerDrafts();
  ref.onDispose(drafts.clear);
  return drafts;
});

/// Call after a session is archived or deleted; an id must never retain an
/// editor controller once it can no longer be reopened.
void clearChatComposerDraft(ProviderContainer ref, String sessionId) =>
    ref.read(chatComposerDraftsProvider).remove(sessionId);
