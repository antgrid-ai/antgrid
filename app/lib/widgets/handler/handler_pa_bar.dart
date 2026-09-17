import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import '../../providers/session_mode.dart';
import '../../providers/sessions.dart';
import '../../providers/value_controller.dart';
import '../../util/detached.dart';
import '../transcript/format.dart';
import 'handler_backlog_drawer.dart';
import 'handler_item_status.dart';
import 'handler_session_settings.dart';

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
/// progress is the summary inflation this guards against.
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
/// Three categories, not two, and the third is the one this prose exists for.
/// Rows a line CLEARS are the ordinary blocking questions. Rows it leaves
/// standing and that are not the user's to answer here are `resolve_in_session`
/// (only the session's own prompt carries the id that resolves it) and
/// `guard_blocked` (a report of an action Handler could not take, retired only
/// by its card's Dismiss) — both are subtracted from the count and otherwise
/// unmentioned. A `nonBlocking` ask is the third: it also survives the line,
/// but it is still the user's to answer, so it is subtracted AND named. Only
/// its own card answers it (`handler:answer` for a tap, an escalationId-bearing
/// `handler:instruct` for typed words) or declines it with a dismiss; a line
/// typed here reaches the agent and leaves the question exactly where it was.
///
/// This prose is a hand-mirror of the bridge's clearing rule; getting it wrong
/// promises the user something the bridge refuses to do.
///
/// [isChat] decides which surface a prompt is sent to, and there is no honest
/// default: the same `resolve_in_session` row is minted for a chat slot's
/// permission card and for a PTY agent's own prompt, so the caller has to say
/// which session it is naming.
///
/// Nothing is ever blocked. Handler's whole premise is acting while you are
/// away, so a lock the user has to remember to undo would be left in the wrong
/// position exactly when it matters.
String? handlerTypingHint(
  HandlerSessionState session, {
  required bool isChat,
}) => switch (session.runState) {
  HandlerRunState.needsYou => _needsYouHint(session, isChat),
  HandlerRunState.parked => _parkedHint(session, isChat),
  HandlerRunState.handling =>
    'Handler is replying — a message now may cross it',
  // Watching is the resting state: nothing is being displaced, so a warning
  // here would be noise on the state the session spends most of its life in.
  HandlerRunState.watching => null,
};

/// An option-based prompt (`kind: 'resolve_in_session'`) is one of the rows
/// a typed line neither answers nor clears — only the session's own resolution
/// UI carries the id, which is why `answerHandlerEscalation` focuses the
/// session instead of opening the reply sheet.
int _prompts(HandlerSessionState session) =>
    session.escalations.where((e) => e.kind == 'resolve_in_session').length;

/// Where that resolution UI actually is, which the session's MODE decides. A
/// chat slot draws the permission card / question form inside the transcript;
/// a PTY agent draws its own prompt in the terminal, and the engine mints the
/// same kind for both (`isBlockingPrompt`, handler/engine.ts). Naming the wrong
/// one sends a terminal user to look for a surface their session does not have.
String _promptSurface(bool isChat) =>
    isChat ? 'the transcript' : 'the terminal';

/// A second one. A `guard_blocked` row reports an action Handler wanted to take
/// and a guard refused, so there is no pause for a line to supersede — the
/// bridge keeps it standing and only the card's Dismiss retires it. A hint that
/// counted it would promise clearing the bridge will not do.
int _reports(HandlerSessionState session) =>
    session.escalations.where((e) => e.kind == 'guard_blocked').length;

/// Questions Handler asked the user that a typed line does not touch. Unlike
/// the other two exemptions this row is still the user's to answer, so it is
/// subtracted from the clear-count AND named in the prose.
int _asks(HandlerSessionState s) =>
    s.escalations.where((e) => e.nonBlocking).length;

/// Appended once to whatever the line already promises, so the user reads one
/// sentence rather than two competing ones.
const _askStaysOpen = " — Handler's question stays open";

/// The clear-count branch names questions the line DOES clear, and those are
/// Handler's too — so beside it the ask needs the possessive to read as a
/// different one.
const _askStaysOpenBesideCleared = " — Handler's own question stays open";

/// Plural because an agent can be stopped on several at once — parallel tool
/// calls raise a permission prompt per call, and the bridge now carries a row
/// for each.
String _promptSubject(int prompts) =>
    prompts == 1 ? 'the prompt' : '$prompts prompts';

String? _needsYouHint(HandlerSessionState session, bool isChat) {
  final asks = _asks(session);
  final prompts = _prompts(session);
  if (prompts > 0) {
    // Both halves or neither. The redirect alone reads as "typing here does
    // nothing", and a user who types anyway loses the free-text questions
    // queued behind the prompt — the silent clearing this whole line exists to
    // stop, merely moved to the mixed case.
    final others = _others(session, prompts);
    final surface = _promptSurface(isChat);
    final answer = 'Answer ${_promptSubject(prompts)} in $surface';
    final questions = others == 1 ? 'question' : '$others questions';
    // "here" is the composer, and it is somewhere OTHER than the prompt only on
    // a chat slot: there the two are separate acts, so the tail warns about a
    // second thing the user might go on to do. A PTY agent draws its prompt in
    // the very terminal the keystrokes go to, which makes them ONE act —
    // arrow-select + Enter is a submit keystroke (`isSubmitKeystroke`,
    // bridge/src/keystrokes.ts), and the bridge answers a submit by clearing
    // every free-text row on the session. Warning about "a message there" would
    // describe the keystroke we just told them to send, so the terminal branch
    // states the consequence instead of naming a second surface.
    final tail = others == 0
        ? (isChat ? ' — not here' : '')
        : isChat
        ? ' — a message here clears the other $questions'
        : ' — that also clears the other $questions';
    final line = '$answer$tail';
    return asks > 0 ? '$line$_askStaysOpen' : line;
  }
  final pending = _others(session, 0);
  // A session standing only on reports is at needs_you with nothing a typed line
  // would clear, so the bar has nothing to warn about. An ask is the one
  // exemption that still needs saying: the line reaches the agent and the
  // question stays, and a user who read nothing here would believe they answered
  // it. That is the worst of the outcomes, so it is the one with no silent arm.
  if (pending == 0) {
    return asks > 0
        ? 'Your next message goes to the agent$_askStaysOpen'
        : null;
  }
  final cleared = pending > 1
      ? 'Your next message clears all $pending questions, answered or not'
      : 'Your next message clears this question, answered or not';
  return asks > 0 ? '$cleared$_askStaysOpenBesideCleared' : cleared;
}

/// The questions a submitted line actually clears: everything the bridge counts,
/// minus the three categories it keeps standing.
///
/// Counted off the bridge's own total rather than the parsed rows, for the same
/// reason the prompt count is subtracted from it — a row the lenient parse
/// dropped must not shrink the number this line promises to clear. Floored: the
/// two arrive in one snapshot but the parse can only ever lose rows, never
/// invent them.
///
/// `pendingEscalations` is `s.escalations.length` on the bridge, so it counts
/// asks too — and a missing subtrahend here does not read as a missing hint, it
/// reads as a promise to clear a question nothing clears.
int _others(HandlerSessionState session, int prompts) => math.max(
  0,
  session.pendingEscalations - prompts - _reports(session) - _asks(session),
);

/// A park ends on the first submitted line either way, but a prompt raised
/// before the park survives it (`enterPark` never touches `s.escalations`), and
/// the engine lands such a session back on `needs_you` rather than resuming —
/// so the bare "resumes Handler" promise is one the bridge refuses to keep.
String _parkedHint(HandlerSessionState session, bool isChat) {
  final prompts = _prompts(session);
  if (prompts == 0) {
    // Reachable rather than theoretical: the park timer's nudge counts only
    // BLOCKING questions, so a session standing on an ask alone parks and
    // self-resumes like any other.
    return _asks(session) > 0
        ? 'Your next message resumes Handler now — its question stays open'
        : 'Your next message resumes Handler now';
  }
  final verb = prompts == 1 ? 'needs' : 'need';
  return 'Your next message ends the pause — ${_promptSubject(prompts)} '
      'still $verb ${_promptSurface(isChat)}';
}

/// A park always resumes on its own, so the wake time carries the message;
/// without a deadline the bare reason is all we can honestly promise.
String _parkedLabel(HandlerSessionState session, DateTime now) {
  final reason = handlerParkReason(session);
  final head = reason == null ? 'Paused' : 'Paused ($reason)';
  final until = session.parkedUntil;
  if (until == null) return head;
  final left = DateTime.fromMillisecondsSinceEpoch(until).difference(now);
  // A deadline already behind us means the resume is in flight, not that the
  // session is overdue — counting into negative time would read as stuck.
  if (left <= Duration.zero) return '$head · resuming';
  return '$head · resumes in ${formatDuration(left)}';
}

/// Whether a countdown is still counting towards something. A deadline already
/// behind us renders a constant string, so a ticker past it repaints once a second
/// for information that cannot change.
bool _hasLiveDeadline(HandlerSessionState session, DateTime now) {
  final until = session.parkedUntil;
  if (session.runState != HandlerRunState.parked || until == null) return false;
  return DateTime.fromMillisecondsSinceEpoch(until).isAfter(now);
}

/// Pinned status line for the focused terminal: what Handler is doing, and
/// what typing will do to it.
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
    final now = DateTime.now();
    _syncCountdownTicker(_hasLiveDeadline(session, now));

    final p = context.antgrid;
    final tone = handlerRunStateColor(p, session.runState);
    final openBacklog =
        ref.watch(handlerBacklogOpenerProvider) ??
        (id) => unawaited(showHandlerBacklogDrawer(context, id));
    // The in-flight target while a mode flip is pending, else the acked entry
    // value — and null reads as NOT chat, the same way `AgentPanel` reads it
    // when it picks the terminal over the transcript. A prompt named for the
    // wrong surface is the failure this bar exists to avoid, and the two
    // surfaces have to agree about which session they are looking at.
    final isChat = ref.watch(activeSessionModeProvider) == 'chat';
    final hint = handlerTypingHint(session, isChat: isChat);
    // An em-dash where this machine has never named the lenses it reads: the
    // chip is read as a live fact about the session, and naming a lens on a
    // machine that never advertised any is a claim about a control over
    // nothing (see HandlerState.lenses). An id this build cannot name is shown
    // as itself for the same reason — a newer machine's lens is a real pick,
    // and folding it into the default would report one the user never made.
    //
    // Every chip label is ≤16 chars precisely so this row can reuse the same
    // vocabulary the sheet chips use rather than fork a second short set (see
    // the redesign spec §11) — no separate bar-only word for the unnamed
    // default.
    //
    // `Your own` has no [roleId] of its own: a preset always clears the brief
    // to `""` on pick (§6), so a non-null [HandlerSessionState.brief] with no
    // [roleId] can only mean the user's own text is what is running.
    final role = session.role;
    final lensLabel = state?.lenses == null
        ? '—'
        : session.roleId != null
        ? (role == null ? session.roleId! : handlerLensLabel(role))
        : session.brief != null
        ? handlerLensOwnLabel
        : handlerLensDefaultLabel;
    // Tinted where nothing is judging: the lens is stored and inert, and a bar
    // naming it in ordinary chrome while every pause escalates says the
    // opposite of what is happening.
    final lensTone = session.observability == HandlerObservability.escalateOnly
        ? p.warning
        : p.textMuted;

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
        title: Text(handlerPaStatusLabel(session, now: now)),
        // Unstyled: AbListRow already renders a subtitle as muted chrome, and
        // restating it here would silently drop the row's line height.
        subtitle: hint == null ? null : Text(hint),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The lens, always — including the default. This bar is on screen
            // for the whole time a session is armed, and it is the only place
            // the setting is visible at all; showing it only once it has been
            // changed makes "no chip" a state the user has to know how to
            // read. It costs width the title is already short of (see the
            // subtitle note above), which is the trade.
            Builder(
              builder: (chipContext) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => detached(
                  'HandlerPaBar',
                  'open session settings',
                  () =>
                      showHandlerSessionSettingsSheet(chipContext, terminalId),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AbChip.system(label: lensLabel, color: lensTone),
                    // The brief sits behind the same door as the lens it
                    // qualifies, so the marker is inside the gesture rather
                    // than beside it: a mark the user cannot follow names
                    // something with nowhere to go and read it.
                    if (session.brief != null)
                      Padding(
                        padding: const EdgeInsets.only(left: AbTokens.space4),
                        child: Semantics(
                          label: 'Brief added',
                          child: AbIcon(
                            AbIcons.comment,
                            size: 11,
                            color: lensTone,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AbTokens.space6),
            AbIcon(AbIcons.chevronUp, size: 12, color: p.textMuted),
          ],
        ),
        onTap: () => openBacklog(terminalId),
      ),
    );
  }
}
