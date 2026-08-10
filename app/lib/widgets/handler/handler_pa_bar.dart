import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../providers/value_controller.dart';
import 'handler_backlog_drawer.dart';
import 'handler_item_status.dart';

/// Opens the backlog drawer for one armed terminal.
typedef HandlerBacklogOpener = void Function(String terminalId);

/// Overrides how the status row opens the backlog; null means
/// [showHandlerBacklogDrawer], which is what every surface that mounts the bar
/// wants. Exists so a test can observe the terminal id the row hands over
/// without standing up a route to catch it.
final handlerBacklogOpenerProvider =
    NotifierProvider<
      ValueController<HandlerBacklogOpener?>,
      HandlerBacklogOpener?
    >(() => ValueController(null));

/// The bar's one-line progress readout for [session], e.g.
/// `Item 2/4: Running integration tests`.
///
/// The ordinal counts completions only, never the other closed states: a
/// skipped or failed item ends without being achieved, and folding it into
/// progress is the summary inflation spec §4.3 guards against.
///
/// With nothing active it defers to [handlerProgressLabel] rather than phrasing
/// the aggregate itself — this bar and the Handler tab are both on screen on
/// desktop, and two wordings of one number read as two numbers.
///
/// [now] is injectable so the parked countdown is deterministic in tests.
String handlerPaStatusLabel(HandlerSessionState session, {DateTime? now}) {
  if (session.runState == HandlerRunState.parked) {
    return _parkedLabel(session, now ?? DateTime.now());
  }
  final total = session.backlogTotal;
  if (total == 0) return 'Nothing queued';
  final done = session.backlogDone;
  for (final item in session.backlog) {
    if (item.status == 'active') return 'Item ${done + 1}/$total: ${item.text}';
  }
  return handlerProgressLabel(session);
}

/// What the user's next message to this session will do to Handler, or null
/// where it does nothing worth warning about.
///
/// Handler and the user drive the SAME agent session, and the engine treats a
/// submitted human line as the user taking the wheel
/// (`HandlerEngine.onUserReply`): it unparks and retires the pending questions
/// without reading a word of what was typed. It CLEARS them rather than
/// answering them, and never says which — so the line has to promise clearing,
/// not answers.
///
/// Nothing is ever blocked. Handler's whole premise is acting while you are
/// away, so a lock the user has to remember to undo would be left in the wrong
/// position exactly when it matters.
String? handlerTypingHint(HandlerSessionState session) =>
    switch (session.runState) {
      HandlerRunState.needsYou => _needsYouHint(session),
      HandlerRunState.parked => _parkedHint(session),
      HandlerRunState.handling =>
        'Handler is replying — a message now may cross it',
      // Watching is the resting state: nothing is being displaced, so a warning
      // here would be noise on the state the session spends most of its life in.
      HandlerRunState.watching => null,
    };

/// An option-based prompt (`kind: 'resolve_in_session'`) is the one row a typed
/// line neither answers nor clears — only the transcript's permission card or
/// question form carries the id that resolves it, which is why
/// `handler_screen.dart`'s `answer()` routes there instead of opening the reply
/// sheet.
int _prompts(HandlerSessionState session) =>
    session.escalations.where((e) => e.kind == 'resolve_in_session').length;

/// Plural because an agent can be stopped on several at once — parallel tool
/// calls raise a permission prompt per call, and the bridge now carries a row
/// for each.
String _promptSubject(int prompts) =>
    prompts == 1 ? 'the prompt' : '$prompts prompts';

String _needsYouHint(HandlerSessionState session) {
  final prompts = _prompts(session);
  if (prompts > 0) {
    // Both halves or neither. The redirect alone reads as "typing here does
    // nothing", and a user who types anyway loses the free-text questions
    // queued behind the prompt — the silent clearing this whole line exists to
    // stop, merely moved to the mixed case.
    final others = session.escalations.length - prompts;
    final answer = 'Answer ${_promptSubject(prompts)} in the transcript';
    if (others == 0) return '$answer — not here';
    final questions = others == 1 ? 'question' : '$others questions';
    return '$answer — a message here clears the other $questions';
  }
  // Kinds come from the per-session rows, the number from the count the bridge
  // folds off that same list, so a row the lenient parse dropped never shrinks
  // the total on screen.
  final pending = session.pendingEscalations;
  return pending > 1
      ? 'Your next message clears all $pending questions, answered or not'
      : 'Your next message clears this question, answered or not';
}

/// A park ends on the first submitted line either way, but a prompt raised
/// before the park survives it (`enterPark` never touches `s.escalations`), and
/// the engine lands such a session back on `needs_you` rather than resuming —
/// so the bare "resumes Handler" promise is one the bridge refuses to keep.
String _parkedHint(HandlerSessionState session) {
  final prompts = _prompts(session);
  if (prompts == 0) return 'Your next message resumes Handler now';
  final verb = prompts == 1 ? 'needs' : 'need';
  return 'Your next message ends the pause — ${_promptSubject(prompts)} '
      'still $verb the transcript';
}

/// A park always resumes on its own, so the wake time carries the message;
/// without a deadline the bare reason is all we can honestly promise.
String _parkedLabel(HandlerSessionState session, DateTime now) {
  final reason = switch (session.parkKind) {
    'limit' => 'rate limit',
    'outage' => 'provider outage',
    _ => null,
  };
  final head = reason == null ? 'Paused' : 'Paused ($reason)';
  final until = session.parkedUntil;
  if (until == null) return head;
  final left = DateTime.fromMillisecondsSinceEpoch(until).difference(now);
  // A deadline already behind us means the resume is in flight, not that the
  // session is overdue — counting into negative time would read as stuck.
  if (left <= Duration.zero) return '$head · resuming';
  return '$head · resumes in ${_countdown(left)}';
}

String _countdown(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

/// Pinned status line for the focused terminal (spec §4.2): what Handler is
/// doing, and what typing will do to it.
///
/// Deliberately ONE row and no input of its own. The composer (or the PTY) sits
/// directly above this, so a second field with its own send button read as a
/// rival composer — two places to type, neither saying who receives it. The
/// instruction field and the 1-tap presets live in the backlog drawer this row
/// opens, where "queue this for later" is plainly a different act from "say this
/// now".
///
/// Renders only for an armed session, so an unarmed terminal gives up no
/// vertical space to it.
class HandlerPaBar extends ConsumerStatefulWidget {
  const HandlerPaBar({super.key});

  @override
  ConsumerState<HandlerPaBar> createState() => _HandlerPaBarState();
}

class _HandlerPaBarState extends ConsumerState<HandlerPaBar> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// The countdown is the only part of the bar that changes without a message
  /// arriving, so it runs a clock — and only while there is a live deadline to
  /// count towards, since everything else here repaints on state alone.
  void _syncCountdownTicker(bool needed) {
    if (needed == (_tick != null)) return;
    if (needed) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final terminalId = ref.watch(activeSessionIdProvider);
    final state = ref.watch(handlerStateProvider).value;
    final session = terminalId == null ? null : state?.sessions[terminalId];
    if (terminalId == null || session == null) {
      _syncCountdownTicker(false);
      return const SizedBox.shrink();
    }
    _syncCountdownTicker(
      session.runState == HandlerRunState.parked && session.parkedUntil != null,
    );

    final p = context.antgrid;
    final tone = switch (session.runState) {
      HandlerRunState.handling || HandlerRunState.needsYou => p.accent,
      HandlerRunState.parked => p.warning,
      HandlerRunState.watching => p.textMuted,
    };
    final openBacklog =
        ref.watch(handlerBacklogOpenerProvider) ??
        (id) => unawaited(showHandlerBacklogDrawer(context, id));
    final hint = handlerTypingHint(session);

    return Container(
      decoration: BoxDecoration(
        color: p.bgDeep,
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      child: AbListRow(
        density: AbRowDensity.sm,
        // The hint's actionable half is its tail ("…answer it in the
        // transcript"), which is exactly what one ellipsized line eats: the
        // narrowest panel that mounts this bar leaves ~216px for a string that
        // wants more than 300. Start-aligned so the icons stay beside the title
        // rather than drifting to the middle of a wrapped block.
        subtitleMaxLines: 2,
        crossAxisAlignment: CrossAxisAlignment.start,
        leading: AbIcon(AbIcons.list, size: 12, color: tone),
        title: Text(handlerPaStatusLabel(session)),
        // Unstyled: AbListRow already renders a subtitle as muted chrome, and
        // restating it here would silently drop the row's line height.
        subtitle: hint == null ? null : Text(hint),
        trailing: AbIcon(AbIcons.chevronUp, size: 12, color: p.textMuted),
        onTap: () => openBacklog(terminalId),
      ),
    );
  }
}
