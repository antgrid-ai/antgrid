import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How many sessions' opening prompts are kept. Only ever read at the moment
/// someone arms Handler, so the useful window is one sitting — the cap exists
/// to bound a long-lived app, not to expire anything.
const int kSessionOpeningPromptCap = 32;

/// How much of one prompt is kept.
///
/// The New Session field is multi-line and built for long input, so pasting a
/// whole issue body into it is an ordinary way to start a session — and this
/// string is sent as the handler goal, which is unbounded on the wire, is
/// interpolated verbatim into EVERY judge prompt for the life of the session,
/// and becomes the wrap-up push body. None of those three bound it; an
/// unbounded goal buys every judged event its tokens and can push the recent
/// context a decision is made from out of a small model's window.
///
/// 400 is the bridge's own `MAX_ITEM_CHARS` (`bridge/src/handler/extract.ts`) —
/// the size it already treats as one item's worth of user text, and exactly
/// what `extractAndAppend` slices to when it falls back to the raw sentence. So
/// a clamped goal and the item it becomes are the same length.
const int kSessionOpeningPromptChars = 400;

/// The sentence a session was started with, keyed by session id.
///
/// Mirrors `session:start.initialPrompt`, which the bridge treats as one-shot
/// launch argv and never persists (protocol.ts), and which
/// `resetNewSessionForm` clears off the composer the moment a start is
/// accepted. So by the time the user arms Handler — a different surface, a
/// later moment — their own words are gone everywhere else. This is the only
/// thing holding them, and the arm flow sends them as the session goal.
///
/// In-memory on purpose: a prompt that outlived a restart would be seeding a
/// goal onto a session the user has long since redirected in the terminal. That
/// narrows the stale-goal window to one app process rather than closing it —
/// [forget] closes it for a session that HAS been armed, and a first arm made
/// hours later still seeds whatever was typed at the start.
class SessionOpeningPrompts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Record [prompt] as what [sessionId] was started to do. A blank prompt
  /// records nothing, so a session started with an empty composer stays
  /// goal-less rather than arming against an empty string.
  void remember(String sessionId, String prompt) {
    final text = prompt.trim();
    if (text.isEmpty) return;
    final next = {...state}..remove(sessionId);
    next[sessionId] = _clamped(text);
    while (next.length > kSessionOpeningPromptCap) {
      next.remove(next.keys.first);
    }
    state = next;
  }

  /// Drop [sessionId]'s prompt, once an arm has actually carried it.
  ///
  /// Seeding is a FIRST-arm act. An arm carrying a goal and no backlog makes the
  /// bridge extract items from that goal, and a plain disarm leaves nothing to
  /// rehydrate — so the same sentence sent on a re-arm re-queues work Handler
  /// has already done, and does it again unattended.
  void forget(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    state = {...state}..remove(sessionId);
  }

  /// Cut on a UTF-16 boundary: `substring` counts code units, and a stranded
  /// surrogate half is not text to put on the wire. No ellipsis — this is read
  /// as instructions, not displayed as a label.
  String _clamped(String text) {
    if (text.length <= kSessionOpeningPromptChars) return text;
    final last = text.codeUnitAt(kSessionOpeningPromptChars - 1);
    final end = (last >= 0xD800 && last <= 0xDBFF)
        ? kSessionOpeningPromptChars - 1
        : kSessionOpeningPromptChars;
    return text.substring(0, end);
  }
}

final sessionOpeningPromptsProvider =
    NotifierProvider<SessionOpeningPrompts, Map<String, String>>(
      SessionOpeningPrompts.new,
    );
