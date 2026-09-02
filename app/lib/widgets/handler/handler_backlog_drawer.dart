import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/handler_state.dart';
import '../../providers/first_run.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../services/handler_service.dart';
import '../../util/detached.dart';
import 'handler_instruction_composer.dart';
import 'handler_item_status.dart';
import 'handler_session_settings.dart';

/// What the sheet is called, and what it is called for. The surface keeps its
/// own name first: a card, a menu entry and the pill all send the user here by
/// the word "backlog", and a title that led with the session would rename the
/// destination halfway through the trip.
String _backlogTitle(String? sessionName) =>
    sessionName == null ? 'Backlog' : 'Backlog · $sessionName';

/// The one copy of this sentence the UI renders. The wording is pinned, not a
/// paraphrase to be tidied: `handler_backlog_drawer_test.dart` spells the same
/// string out literally instead of comparing against this constant, so a
/// reword here fails there rather than shipping unnoticed.
const handlerDisclaimerText =
    "Handler acts on your behalf while you're away and can make mistakes. "
    'Flagged actions are listed in the activity log and can be undone.';

/// Opens the backlog editor for [terminalId] as the shared adaptive sheet.
Future<void> showHandlerBacklogDrawer(
  BuildContext context,
  String terminalId,
) => showAbAdaptiveSheet<void>(
  context,
  child: HandlerBacklogDrawer(terminalId: terminalId),
);

/// The live instruction stack for one armed session, with the four edits the
/// user is allowed to make: reorder, drop an item, drop a dependency, and
/// requeue a stalled one.
///
/// Deliberately offers no way to CREATE a dependency: the bridge derives
/// `dependsOn` from the user's own ordering words, and a hand-authored one
/// silently blocks work they asked for.
class HandlerBacklogDrawer extends ConsumerWidget {
  const HandlerBacklogDrawer({super.key, required this.terminalId});

  final String terminalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final state = ref.watch(handlerStateProvider).value;
    final session = state?.sessions[terminalId];
    final backlog = session?.backlog ?? const <HandlerInstructionItem>[];
    // Indexed once per rebuild rather than searched per link: every waits-on
    // line resolves against this same list, so a backlog near the bridge's cap
    // otherwise walks it again for each one.
    final byId = {for (final i in backlog) i.id: i};
    // Keyed by terminal, so a rebuild for a different terminalId cannot draw
    // one session's outstanding instruction under another's backlog.
    final pending =
        state?.pendingInstructionsFor(terminalId) ?? const <String>[];
    final editLock = handlerEditLockReason(pending);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            _backlogTitle(_sessionName(ref, terminalId)),
            onClose: () => Navigator.of(context).maybePop(),
            // Budgeted for two lines: a generated session name runs to 60
            // characters and a renamed one to whatever the user typed, so
            // "Backlog · <name>" wraps on a phone as the ordinary case rather
            // than the edge. Every other caller of this helper passes a
            // constant that never reaches a second line.
            wraps: true,
          ),
        ),
        if (session != null && session.goal.trim().isNotEmpty)
          _GoalLine(goal: session.goal.trim()),
        if (session != null && backlog.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbTokens.space16,
              AbTokens.space4,
              AbTokens.space16,
              0,
            ),
            child: Text(
              handlerProgressLabel(session),
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textMuted,
              ),
            ),
          ),
        if (editLock != null) _EditLockNotice(reason: editLock),
        const SizedBox(height: AbTokens.space8),
        Flexible(
          // An outstanding instruction keeps the list on screen on its own: an
          // invitation to add something is exactly the wrong thing to print
          // over a sentence the user has just added.
          child: backlog.isEmpty && pending.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AbTokens.space16,
                    vertical: AbTokens.space24,
                  ),
                  child: _NothingQueued(
                    armed: session != null,
                    hasGoal: session?.goal.trim().isNotEmpty ?? false,
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: backlog.length + pending.length,
                  itemBuilder: (_, index) => index >= backlog.length
                      ? _PendingInstructionRow(
                          text: pending[index - backlog.length],
                        )
                      : _BacklogRow(
                          terminalId: terminalId,
                          item: backlog[index],
                          canMoveUp: index > 0,
                          canMoveDown: index < backlog.length - 1,
                          labelFor: (id) => _dependencyLabel(byId, id),
                          lockReason: editLock,
                        ),
                ),
        ),
        // Only for a session that can receive one: an unarmed terminal has no
        // backlog to add to, and offering the field anyway would send into a
        // supervisor that is not running.
        if (session != null) ...[
          _InstructionComposer(terminalId: terminalId),
          const _Disclaimer(),
        ] else
          const SizedBox(height: AbTokens.space8),
      ],
    );
  }
}

/// The session's own name, read from the same list the Handler tab's cards name
/// their rows from — one session described two ways by two surfaces of one
/// feature reads as two sessions.
///
/// Null where the tab would fall back to the raw terminal id. An id there tells
/// rows apart on a screen listing several; here it would stand in a title over
/// the only session on screen, spending the line on a string with nothing to
/// distinguish it from.
String? _sessionName(WidgetRef ref, String terminalId) {
  for (final s in ref.watch(activeSessionsProvider)) {
    if (s.id != terminalId) continue;
    return s.name.trim().isEmpty ? null : s.name;
  }
  return null;
}

/// An armed session with nothing in its list: a session the app adopted rather
/// than started, an arm after a restart, an empty composer, a list the user
/// emptied themselves — or a seeded arm whose extraction has not landed yet,
/// which is a headless CLI run of up to ~20 seconds and is the likeliest moment
/// of all for this sheet to be open, since the shield and the backlog entry sit
/// one tap apart.
///
/// So it opens with the act rather than the absence, and answers the question an
/// empty list raises in every one of those cases — whether an unfed Handler is
/// doing anything at all. It offers no button: the composer is already on
/// screen under this list, and a second route to one action is how one action
/// ends up with two names.
///
/// [hasGoal] is what stops the invitation reading as "nothing was received".
/// The goal stands above this list and the bridge extracts items from it, so a
/// user told to add what they want done would retype the sentence they started
/// the session with — and the extraction that is already running appends it a
/// second time. Naming the goal instead invites what is genuinely missing.
class _NothingQueued extends StatelessWidget {
  const _NothingQueued({
    required this.armed,
    required this.hasGoal,
  });

  /// False for a terminal Handler was never armed on — a state with no
  /// invitation to make, since nothing here would receive it.
  final bool armed;

  /// Whether a goal is stated above this list.
  final bool hasGoal;

  @override
  Widget build(BuildContext context) => armed
      ? AbEmptyState(
          title: hasGoal
              ? 'Nothing queued beyond the goal above.'
              : "Add what you want done while you're away.",
          subtitle:
              'Handler already answers what the agent pauses on. A backlog '
              'is the work it takes on by itself.',
        )
      // The Handler tab's own direction, verbatim: one instruction worded one
      // way wherever the user meets it.
      : const AbEmptyState(
          title: 'Handler is not armed on this session.',
          subtitle: 'Arm it with the shield at the end of the top bar.',
        );
}

/// What the list is for, in the user's own words — and, since an arm carrying a
/// goal is what the bridge extracts the backlog from, where these items came
/// from. This sheet is where a user goes to ask that, and it is the only surface
/// that can answer: the card it opens from shows the goal as a headline and says
/// nothing about its relationship to the list underneath.
class _GoalLine extends StatelessWidget {
  const _GoalLine({required this.goal});

  final String goal;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space4,
        AbTokens.space16,
        0,
      ),
      child: Text(
        'Working towards: $goal',
        // The goal is a sentence the user typed on the New Session canvas at
        // whatever length suited them, and one line clips most of a pasted one.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        // A step brighter than the progress line below it: this is the user's
        // own words, not a count the app derived.
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: p.textSecondary,
        ),
      ),
    );
  }
}

/// The instruction box, here rather than pinned above the session composer.
///
/// Queueing work for Handler to do later is a different act from talking to the
/// agent now, and the two fields stacked said otherwise: same shape, same send
/// glyph, destination stated only in a hint. One field is pinned to the session
/// (the composer, or the PTY); this one is a deliberate detour.
class _InstructionComposer extends ConsumerStatefulWidget {
  const _InstructionComposer({required this.terminalId});

  final String terminalId;

  @override
  ConsumerState<_InstructionComposer> createState() =>
      _InstructionComposerState();
}

class _InstructionComposerState extends ConsumerState<_InstructionComposer> {
  final _input = TextEditingController();

  /// The sentence a send was held for, if one was. Rendered only while that
  /// sentence is still outstanding, which is exactly as long as the refusal is
  /// true — so the line retires itself and needs no timer to take it away.
  String? _held;

  /// The sentence a send is waiting on a grant for, and the newest grant the
  /// feed already held when it went.
  ///
  /// The echo below reports what ONE sentence also allowed, so both halves are
  /// needed. A grant made an hour ago is not news — it is history the activity
  /// feed already holds, and standing it over the field on every open would turn
  /// an echo into a permanent statement of the session's standing permissions,
  /// which is a surface for managing them and not one this sheet offers. Nor is
  /// a grant that landed while nothing of ours was in flight: `handler:instruct`
  /// reaches this terminal from the phone too, and a high-water mark alone
  /// attributed that phone's lift to whatever the field last sent.
  String? _awaitingGrantFor;
  String? _grantAnchor;

  /// The grant attributed to [_awaitingGrantFor], once one has been. Latched,
  /// because the status snapshot that retires the sentence lands right behind
  /// the activity row carrying the grant — a line gated on the sentence still
  /// being outstanding would show for a frame and go.
  HandlerActivityRecord? _echoed;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Newest first, the order the service prepends activity in.
  HandlerActivityRecord? _newestGrant(HandlerState? state) {
    for (final r in state?.activity ?? const <HandlerActivityRecord>[]) {
      if (r.terminalId == widget.terminalId &&
          r.decision == 'instruction_authorized') {
        return r;
      }
    }
    return null;
  }

  /// Resolved through the container for the same reason [_sendEdit] is: this
  /// fires from a tap inside a sheet, which the send itself may pop.
  ///
  /// The service owns both the empty check and the debounce; this only decides
  /// what the user is told about it. A blank field is silent — there was
  /// nothing to send and the user knows it — while a duplicate is a send that
  /// looked identical to one that worked and did not happen, on the primary
  /// action of the surface.
  HandlerInstructResult _instruct(String text) {
    final result =
        focusedServiceOrNull(
          ref.container,
          (s) => s.handlerService,
        )?.instruct(widget.terminalId, text) ??
        HandlerInstructResult.empty;
    setState(() {
      _held = result == HandlerInstructResult.duplicate ? text.trim() : null;
      if (result == HandlerInstructResult.sent) {
        _awaitingGrantFor = text.trim();
        _grantAnchor = _newestGrant(
          ref.read(handlerStateProvider).value,
        )?.recordId;
        _echoed = null;
      }
    });
    return result;
  }

  /// A grant arrives as an activity row of its own, ahead of the status snapshot
  /// that retires the sentence — so the attribution has to be made while the
  /// sentence is still outstanding, and kept once it no longer is.
  void _adoptGrant(HandlerState? state) {
    final sentence = _awaitingGrantFor;
    if (sentence == null || _echoed != null) return;
    final outstanding =
        state?.pendingInstructionsFor(widget.terminalId) ?? const <String>[];
    if (!outstanding.contains(sentence)) return;
    final grant = _newestGrant(state);
    if (grant == null || grant.recordId == _grantAnchor) return;
    setState(() => _echoed = grant);
  }

  void _submitTyped() {
    // Cleared only on a send that happened: a refused one would take the
    // user's words with it and leave an empty field beside an unchanged list.
    if (_instruct(_input.text) != HandlerInstructResult.sent) return;
    _input.clear();
  }

  HandlerSessionSettingsValue? _judge;

  /// Seeded once, from the service rather than from a provider — the same rule
  /// [_SettingsSheet] follows: reseeding on every rebuild lets the status
  /// snapshot that confirms an edit land mid-gesture and reset the control.
  HandlerSessionSettingsValue get _judgeValue =>
      _judge ??
      handlerSessionSettingsFor(
        focusedServiceOrNull(ref.container, (s) => s.handlerService),
        widget.terminalId,
      );

  /// The judge is what READS the sentence typed above it, so picking one here
  /// commits immediately rather than waiting on some absent Save.
  ///
  /// `armed: true` on an already-armed session is the bridge's EDIT path — but
  /// on a session that is GONE it is a fresh arm, which retires that slot's undo
  /// offers. This composer mounts under `session != null`, but the judge PANEL
  /// it opens is a route that outlives it: a wrap-up disarming the session under
  /// an open drawer unmounts this State while the panel is still up and can
  /// still call back. Hence both guards, not just the mount condition.
  void _commitJudge(HandlerJudgePick pick) {
    if (!mounted) return;
    final service = focusedServiceOrNull(
      ref.container,
      (s) => s.handlerService,
    );
    final stillArmed =
        ref.read(handlerStateProvider).value?.sessions[widget.terminalId] !=
        null;
    if (service == null || !stillArmed) return;
    final next = (
      judgeTool: pick.judgeTool,
      judgeModel: pick.judgeModel,
      personality: _judgeValue.personality,
    );
    final edit = handlerSessionSettingsEdit(_judgeValue, next);
    // Pinned only once the send is real: `_judgeValue` prefers `_judge`, so a
    // value pinned ahead of a dropped send is one no status frame can correct,
    // and every later delta is computed against a `from` the bridge never held.
    service.arm(
      terminalId: widget.terminalId,
      judgeTool: edit.judgeTool,
      judgeModel: edit.judgeModel,
    );
    setState(() => _judge = next);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(handlerStateProvider, (_, next) => _adoptGrant(next.value));
    final p = context.antgrid;
    final held = _held;
    final outstanding =
        ref
            .watch(handlerStateProvider)
            .value
            ?.pendingInstructionsFor(widget.terminalId) ??
        const <String>[];
    final stillHeld = held != null && outstanding.contains(held) ? held : null;
    final echoed = _echoed;
    final granted = echoed == null ? null : _grantLiterals(echoed);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      padding: const EdgeInsets.only(top: AbTokens.space8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              AbTokens.space16,
              AbTokens.space8,
              AbTokens.space16,
              stillHeld == null && granted == null
                  ? AbTokens.space8
                  : AbTokens.space4,
            ),
            child: HandlerInstructionComposer(
              terminalId: widget.terminalId,
              controller: _input,
              // "Send", not "Add": a sentence here can take a line off this
              // list or reword one as readily as it can add one, and a control
              // promising to add is at its most wrong exactly when the user is
              // cancelling something.
              hintText: 'Send an instruction…',
              judge: (
                judgeTool: _judgeValue.judgeTool,
                judgeModel: _judgeValue.judgeModel,
              ),
              onJudgeChanged: _commitJudge,
              judgeScopeNote: handlerJudgeScopeNextPass,
              send: HandlerComposerSend(
                tooltip: 'Send to Handler',
                semanticLabel: 'Send to Handler',
                onSend: _submitTyped,
              ),
            ),
          ),
          // Answered where the send was made, and in the same verb the field,
          // the button and the waiting row all use. Without it a held duplicate
          // moves nothing on screen: the field keeps the user's words, the list
          // is unchanged, and the tail row saying so may be scrolled away —
          // which is a broken button, not a debounce.
          if (stillHeld != null)
            // Full width so the line starts on the composer's own left edge;
            // the column around it centres anything that sizes to its child.
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AbTokens.space16,
                  0,
                  AbTokens.space16,
                  AbTokens.space8,
                ),
                child: Text(
                  'Already sending "${_quoted(stillHeld)}".',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textSecondary,
                  ),
                ),
              ),
            ),
          if (granted != null && granted.isNotEmpty)
            _GrantEcho(granted: granted),
        ],
      ),
    );
  }
}

/// What the sentence just sent ALSO did. An instruction reads as a chore —
/// "clear out the build dir with rm -rf build" — and the lift it takes stands
/// for the rest of the session: Handler runs that shape from here on without
/// the advisory row that would otherwise name it. That is the one consequence
/// of this field a user cannot read off their own sentence.
///
/// Deliberately not behind the disclaimer's dismissal. That flag retires one
/// notice once it has been read; this line carries different words every time it
/// appears, and inheriting the flag would hide the grants made after the first.
///
/// Says what was allowed and for how long, and stops. The count and the audit
/// trail are the activity feed's job, one screen up.
class _GrantEcho extends StatelessWidget {
  const _GrantEcho({required this.granted});

  /// Commands, absolute paths and hosts, as the bridge joined them.
  final String granted;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Full width so the lines start on the composer's own left edge; the
    // column around it centres anything that sizes to its child.
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AbTokens.space16,
          0,
          AbTokens.space16,
          AbTokens.space8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Also allowed for the rest of this session:',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textSecondary,
              ),
            ),
            Text(
              granted,
              // Clipped rather than wrapped away: a wide instruction can name more
              // than fits, and the bridge appends its own "+N more" so the sample
              // says how much it left out wherever it is read.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: p.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The literals a grant row carries, wherever the bridge put them: a lone lift
/// rides in the reason — the feed row leads with it rather than with a count of
/// one — and anything wider is sampled into the detail.
String _grantLiterals(HandlerActivityRecord r) {
  final detail = r.detail?.trim() ?? '';
  return detail.isEmpty ? r.reason : detail;
}

/// Handler acts first and is read hours later, so there is no review step in
/// which the undo path could be stumbled upon at the moment it is wanted —
/// this puts it in front of the user beforehand. It makes undo discoverable;
/// it does not make a bad outcome less likely.
///
/// Closable, and nothing stands where it was. Two lines under the composer on
/// every open is a standing tax for a sentence that stops being news after the
/// first read, and the Undo list it points at has its own pinned section header
/// one layer up on the screen this sheet opens from — so past the first read
/// the job is already done there, and a residual affordance here would be a
/// permanent control whose whole content is a line the user has dismissed.
class _Disclaimer extends ConsumerWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final dismissed = ref.watch(
      firstRunProvider.select((s) => s.handlerDisclaimerDismissed),
    );
    if (dismissed) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              handlerDisclaimerText,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: p.textMuted,
              ),
            ),
          ),
          const SizedBox(width: AbTokens.space6),
          // The away hint's own wording for the same gesture: one permanent
          // dismissal, named the same way wherever the user meets it.
          AbIconButton(
            icon: AbIcons.close,
            tooltip: "Dismiss — won't show again",
            tone: AbIconButtonTone.muted,
            onTap: () =>
                ref.read(firstRunProvider.notifier).dismissHandlerDisclaimer(),
          ),
        ],
      ),
    );
  }
}

/// The one line under an item's text, and which of its two facts gets it.
///
/// `outcome` outranks `condition` wherever both exist. The condition is the
/// question "does this still need doing?" and the outcome is its answer, so
/// once one is written the other reads as stale. It is also the only fact here
/// with nowhere else to live: the gate is implied by the item's own text and by
/// its status sitting at `queued`, while what actually happened is written by
/// the bridge and rendered by nothing.
///
/// `evidence` deliberately stays off the row. It is the verbatim transcript
/// quote backing the outcome, and this list is scanned for what happened rather
/// than for what was said — putting the proof beside the claim would cost the
/// claim the line it earned.
Widget? _itemSubtitle(HandlerInstructionItem item) {
  final outcome = item.outcome;
  if (outcome != null && outcome.trim().isNotEmpty) return Text(outcome);
  final condition = item.condition;
  if (condition != null && condition.trim().isNotEmpty) {
    return Text('only if $condition');
  }
  return null;
}

/// What an item waits on, in the user's own words when the id still resolves to
/// a live item — a bare id says nothing about what is holding the work up.
///
/// [status] is the dependency's own, and is null exactly when the id resolves to
/// nothing: an unresolved dependency is a state nobody can report on. It rides
/// along because whether this item can move is a fact about the item it waits
/// on, and the row is the only place holding both.
({String text, bool resolved, String? status}) _dependencyLabel(
  Map<String, HandlerInstructionItem> byId,
  String id,
) {
  final item = byId[id];
  return item == null
      ? (text: id, resolved: false, status: null)
      : (text: item.text, resolved: true, status: item.status);
}

/// How much of the user's own sentence the lock reason quotes back. It has to
/// fit a tooltip, and the sentence is however much the user felt like typing.
const _quotedInstructionChars = 60;

String _quoted(String sentence) {
  if (sentence.length <= _quotedInstructionChars) return sentence;
  // Back off a trailing high surrogate: `substring` cuts UTF-16 code units, and
  // a stranded half renders as a replacement glyph.
  final last = sentence.codeUnitAt(_quotedInstructionChars - 1);
  final end = (last >= 0xD800 && last <= 0xDBFF)
      ? _quotedInstructionChars - 1
      : _quotedInstructionChars;
  return '${sentence.substring(0, end)}…';
}

/// Why the backlog cannot be edited right now, or null while it can.
///
/// Every edit is a wholesale `handler:configure`, and the items an outstanding
/// instruction becomes are appended behind that handoff — so an edit sent in
/// between replaces the bridge's list with one the new items were never in, and
/// the work the user just asked for is gone with nothing said. The window is
/// the length of an extraction and the user has no reason to suspect it.
///
/// The reason quotes their sentence rather than describing the app's state:
/// the row wearing [handlerPendingInstructionLabel] is on screen while this is
/// refusing, and the quote is what makes the two one fact instead of two. It
/// names the end of the hold rather than the data loss it prevents, because it
/// stands on screen for the whole window (see [_EditLockNotice]) and the
/// question a user reads it with is when the list comes back, not what the
/// bridge would otherwise have done to it.
String? handlerEditLockReason(List<String> pending) {
  if (pending.isEmpty) return null;
  if (pending.length > 1) {
    return 'Still sending ${pending.length} instructions — editing is paused '
        'until they land.';
  }
  return 'Still sending "${_quoted(pending.single)}" — editing is paused '
      'until it lands.';
}

/// Why the list is not the user's to edit right now, standing for exactly as
/// long as that is true.
///
/// The reason used to be delivered only on a tap — a tooltip on hover, a snack
/// bar on a press — and on a phone neither arrives. This drawer opens as a
/// modal sheet, and a snack bar goes through `ScaffoldMessenger` to the page's
/// own `Scaffold`, which is the route UNDERNEATH it; the menu that raises one
/// sits a layer above the sheet again. A tooltip is long-press-only on touch.
/// So the explanation stops being something the user has to ask for: the hold
/// lasts one extraction and ends on its own, and a line that arrives and leaves
/// with it answers every held control at once, before any of them is touched.
///
/// [_ItemEditor] gives this slot the rest of its refusals too — one place a
/// held edit is explained, whatever is holding it.
class _EditLockNotice extends StatelessWidget {
  const _EditLockNotice({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space4,
        AbTokens.space16,
        0,
      ),
      child: Text(
        reason,
        // A step brighter than the progress line above it, and no louder. The
        // usual reason is a hold the user caused by asking for something; the
        // rest sit under a Save already greyed out, which says "not now" loudly
        // enough on its own.
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: p.textSecondary,
        ),
      ),
    );
  }
}

/// Sends [edit] applied to the FRESHEST backlog readable at the moment of the
/// tap. `handler:configure` replaces the bridge's list wholesale with no merge,
/// and extraction appends to it asynchronously behind the handoff, so an edit
/// derived from anything older silently deletes whatever landed in between —
/// which is also why the edited list is never held across an await.
///
/// The refusal covering that same window lives in [HandlerService.updateBacklog]
/// rather than here: this file is one editing surface, and the service is the
/// only way any of them reaches the wire. What is owed here is the reason —
/// [handlerEditLockReason], on every affordance and standing above the list.
///
/// Takes the container rather than a `WidgetRef` because a menu entry fires
/// after its route pops, by which time a status update may have taken this row
/// out of the tree.
///
/// [edit] returning null means the item it names is no longer in the list it
/// was handed, which is a refusal rather than a replace of the list with
/// itself: a `handler:configure` built from a miss changes nothing on the
/// bridge and would report success for an edit that never happened.
///
/// Reports WHY the edit did not reach the wire. Every caller but one discards
/// it — a reorder or a delete refused is a list that simply did not move, and
/// [_EditLockNotice] is already on screen saying why. [_ItemEditor] is the
/// exception, because a refusal there would take the user's typing with it,
/// and the two refusals end differently: a hold lifts itself, a destination
/// that is gone does not.
_EditSend _sendEdit(
  ProviderContainer container,
  String terminalId,
  List<HandlerInstructionItem>? Function(List<HandlerInstructionItem>) edit,
) {
  final service = focusedServiceOrNull(container, (s) => s.handlerService);
  if (service == null) return _EditSend.unreachable;
  final session = service.currentState.sessions[terminalId];
  if (session == null) return _EditSend.unreachable;
  final next = edit(session.backlog);
  if (next == null) return _EditSend.unreachable;
  return service.updateBacklog(
        terminalId: terminalId,
        backlog: next,
      )
      ? _EditSend.sent
      : _EditSend.held;
}

/// What became of one [_sendEdit].
enum _EditSend {
  sent,

  /// [HandlerService.updateBacklog] refused it: an instruction is outstanding
  /// for this terminal, and the window ends when the extraction lands.
  held,

  /// There was nothing to send it to — no focused service, no session under
  /// that terminal, or an item that has left the backlog the edit names.
  /// Nothing about waiting fixes any of the three.
  unreachable,
}

List<HandlerInstructionItem> _withoutItem(
  List<HandlerInstructionItem> backlog,
  String id,
) => [
  for (final i in backlog)
    if (i.id != id) i,
];

/// Moves one item a slot along. List order is the only record of the sequence
/// the user asked for things in when they used no ordering word, so it is
/// editable in its own right.
///
/// The move is addressed by id, not by the rendered index: the list the row was
/// drawn from may already have grown behind it.
List<HandlerInstructionItem> _withItemMoved(
  List<HandlerInstructionItem> backlog,
  String id,
  int delta,
) {
  final from = backlog.indexWhere((i) => i.id == id);
  if (from < 0) return backlog;
  final to = from + delta;
  if (to < 0 || to >= backlog.length) return backlog;
  final next = [...backlog];
  next.insert(to, next.removeAt(from));
  return next;
}

/// Lifts one item to the head of the queue, which is the slot deciding what
/// Handler picks up next — the only reorder worth its own entry, since reaching
/// it a slot at a time costs a wholesale replace per slot.
///
/// The distance is measured against the list the edit is applied to for the
/// same reason [_withItemMoved] addresses by id: the list a row was drawn from
/// may already have grown behind it.
List<HandlerInstructionItem> _withItemAtTop(
  List<HandlerInstructionItem> backlog,
  String id,
) => _withItemMoved(backlog, id, -backlog.indexWhere((i) => i.id == id));

List<HandlerInstructionItem> _withoutDependency(
  List<HandlerInstructionItem> backlog,
  String itemId,
  String dependencyId,
) => [
  for (final i in backlog)
    if (i.id != itemId) i else _itemWithoutDependency(i, dependencyId),
];

HandlerInstructionItem _itemWithoutDependency(
  HandlerInstructionItem item,
  String dependencyId,
) {
  final rest = [
    for (final d in item.dependsOn ?? const <String>[])
      if (d != dependencyId) d,
  ];
  return HandlerInstructionItem(
    id: item.id,
    text: item.text,
    // An emptied list is nulled rather than sent empty, so the wire says
    // "waits on nothing" the same way an item that never had a dependency does.
    dependsOn: rest.isEmpty ? null : rest,
    condition: item.condition,
    status: item.status,
    outcome: item.outcome,
    evidence: item.evidence,
    createdAt: item.createdAt,
  );
}

/// Statuses an item can be put back in the queue from. Both are states it sits
/// in without having been achieved — `skipped` because a precondition did not
/// hold, `blocked` because something it waits on has not cleared — so both are
/// revivable. `done` and `failed` are outcomes the agent reached, and re-running
/// them behind the user's back is not what "revive" means.
///
/// Requeueing is not a promise that the item runs next: a dependency still short
/// of `done` leaves it sitting at `queued` until that clears, which is the honest
/// answer and what the "waits on" line already says.
const _requeueableStatuses = {'skipped', 'blocked'};

/// Dependency statuses the bridge derives a block from, so an item waiting on
/// one of them is re-blocked on the very next pass whatever the user sets it to.
/// Requeue is withheld there rather than offered as an edit that bounces: what
/// frees the item is dropping the dependency, and that stays on the row.
const _stallingStatuses = {'blocked', 'failed'};

/// Statuses the item has already run to, whatever the answer was. A gate on one
/// of these cannot fire again and the row prints the outcome in its place (see
/// [_itemSubtitle]) — so the editor leaves the clause off for the same reason
/// the menu leaves Requeue off: the action applies to nothing.
const _finishedStatuses = {'done', 'failed'};

/// Puts a stalled item back in the queue.
List<HandlerInstructionItem> _withItemRequeued(
  List<HandlerInstructionItem> backlog,
  String id,
) => [
  for (final i in backlog)
    if (i.id != id || !_requeueableStatuses.contains(i.status))
      i
    else
      HandlerInstructionItem(
        id: i.id,
        text: i.text,
        dependsOn: i.dependsOn,
        condition: i.condition,
        status: 'queued',
        // Outcome and evidence justify the status they were written for, and
        // the bridge shows the judge an item's outcome verbatim, so one left on
        // queued work reports a block that is over. The cost is real and falls
        // on a block the judge called on a precondition rather than a
        // dependency ("no staging credentials are configured"): that sentence
        // is stated nowhere else and does not come back, where a dependency
        // block restates itself on the next pass. Requeueing is the user saying
        // the precondition no longer holds, so the reason goes with it.
        createdAt: i.createdAt,
      ),
];

/// How long an item is allowed to be, mirroring the bridge's `MAX_ITEM_CHARS`
/// (`bridge/src/handler/extract.ts`), for `condition` as well as `text`.
///
/// It is the EXTRACTOR's ceiling, not a `handler:configure` rule — the wire
/// item takes a bare string. So this is not validation the bridge would perform
/// anyway; it is what keeps an item the user reworded the same size as every
/// item the extractor minted. The judge is shown the backlog as a list, and one
/// entry the length of a paragraph crowds out the rest of it.
const handlerMaxItemChars = 400;

/// Replaces what an item SAYS, and nothing else about it.
///
/// Status, outcome, evidence and `dependsOn` all ride through untouched: the
/// user changed the wording, not what happened. Unlike a requeue, this leaves
/// the item where it stands — a reworded `done` item is still done, and its
/// outcome is still the record of that.
///
/// [condition] null drops the clause, so an emptied field says "runs whenever
/// its turn comes" on the wire the same way an item that never had one does.
///
/// Null where [id] is not in [backlog] any more. The item can leave under an
/// open editor — a phone driving the same bridge deletes it, the bridge drops
/// it — and a list quietly returned unchanged would go out as a replace that
/// changed nothing, close the sheet, and lose the user's wording behind what
/// reads as a save.
List<HandlerInstructionItem>? _withItemRetexted(
  List<HandlerInstructionItem> backlog,
  String id, {
  required String text,
  required String? condition,
}) {
  if (!backlog.any((i) => i.id == id)) return null;
  return [
    for (final i in backlog)
      if (i.id != id)
        i
      else
        HandlerInstructionItem(
          id: i.id,
          text: text,
          dependsOn: i.dependsOn,
          condition: condition,
          status: i.status,
          outcome: i.outcome,
          evidence: i.evidence,
          createdAt: i.createdAt,
        ),
  ];
}

/// The user's sentence, between the send and the items it becomes.
///
/// It sits at the tail of the list because that is where `appendItems` puts
/// what the extractor makes of it, so the row's position is the truth rather
/// than a placeholder's guess. It is not a stand-in for one item either: a
/// sentence can land as several, under wording the bridge chose, which is why
/// this shows what the user wrote and claims nothing about the shape of what
/// arrives.
///
/// No menu, for the same reason. `handler:configure` replaces a backlog this
/// instruction is not in yet and cannot reach the extraction already running,
/// so a Delete here would clear the row and let the items land anyway.
class _PendingInstructionRow extends StatelessWidget {
  const _PendingInstructionRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return AbListRow(
      horizontalPadding: AbTokens.space16,
      leading: const HandlerPendingLabel(),
      title: Text(text, style: AbTokens.sansStyle(color: p.textSecondary)),
    );
  }
}

class _BacklogRow extends ConsumerWidget {
  const _BacklogRow({
    required this.terminalId,
    required this.item,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.labelFor,
    required this.lockReason,
  });

  final String terminalId;
  final HandlerInstructionItem item;
  final bool canMoveUp;
  final bool canMoveDown;
  final ({String text, bool resolved, String? status}) Function(String id)
  labelFor;

  /// [handlerEditLockReason] for this session, non-null while every edit on
  /// this row is held.
  final String? lockReason;

  /// Whether something this item waits on is itself stalled, which is what
  /// decides between the two ways out of `blocked`.
  bool get _waitsOnStalledWork => (item.dependsOn ?? const <String>[]).any(
    (id) => _stallingStatuses.contains(labelFor(id).status),
  );

  /// One menu entry, carrying the lock. Built through here rather than at each
  /// site so an entry added later cannot be the one that still ships a stale
  /// list.
  AbMenuItem _entry({
    required String label,
    required String icon,
    required VoidCallback onTap,
    bool danger = false,
  }) => AbMenuItem(
    label: label,
    icon: icon,
    danger: danger,
    onTap: onTap,
    enabled: lockReason == null,
    disabledReason: lockReason,
  );

  /// The editor is a route of its own rather than a field opened inside the
  /// row. A row that grew into a form would push every item below it down the
  /// moment the menu closed, and on a phone the keyboard would then cover the
  /// list it was reordering — [showAbAdaptiveSheet] pads for that inset itself,
  /// and leaves the backlog where the user left it.
  Future<void> _openEditor(BuildContext context) => showAbAdaptiveSheet<void>(
    context,
    child: _ItemEditor(terminalId: terminalId, item: item),
  );

  Future<void> _openMenu(
    BuildContext context,
    ProviderContainer container,
  ) async {
    final anchor = abMenuAnchorRect(context);
    if (anchor == null) return;
    // The navigator, not this row: [showAbMenu] pops before it calls an entry,
    // and by then a status frame may have shortened the list out from under the
    // row that was tapped. A navigator outlives every route it hosts, so the
    // editor opens over the drawer either way.
    final navigator = Navigator.of(context);
    await showAbMenu<void>(
      context: context,
      anchorRect: anchor,
      preferred: AbMenuPlacement.above,
      width: 200,
      entries: [
        // First, and on every row whatever its status. The text an item is
        // judged against was written by the extraction pass, which splits one
        // sentence into several, rewords them and cuts them at
        // [handlerMaxItemChars] — so a wrong item is far more often mis-worded
        // than misplaced, and Delete-and-retype costs another extraction.
        _entry(
          label: 'Edit',
          icon: AbIcons.edit,
          onTap: () => detached(
            'HandlerBacklogDrawer',
            'open item editor',
            () => _openEditor(navigator.context),
          ),
        ),
        // Inapplicable actions are omitted, never shown disabled: an edge item
        // has nowhere to move, a finished one has nothing to requeue, and an
        // item behind stalled work would be re-blocked before the user looked
        // away. An edit held by [lockReason] is the other case and stays on the
        // menu greyed: the action applies, it is the moment that doesn't, and
        // dropping it would answer "why can't I move this" with a shorter menu.
        if (canMoveUp) ...[
          // Offered without its mirror. The queue runs from the top, so lifting
          // an item ahead is a change that holds, while sending one to the
          // bottom is undone by the next instruction — extraction appends.
          _entry(
            label: 'Move to top',
            icon: AbIcons.moveToTop,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemAtTop(b, item.id),
            ),
          ),
          _entry(
            label: 'Move up',
            icon: AbIcons.arrowUp,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemMoved(b, item.id, -1),
            ),
          ),
        ],
        if (canMoveDown)
          _entry(
            label: 'Move down',
            icon: AbIcons.arrowDown,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemMoved(b, item.id, 1),
            ),
          ),
        if (_requeueableStatuses.contains(item.status) && !_waitsOnStalledWork)
          _entry(
            label: 'Requeue',
            icon: AbIcons.refresh,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemRequeued(b, item.id),
            ),
          ),
        const AbMenuDivider(),
        _entry(
          label: 'Delete',
          icon: AbIcons.trash,
          danger: true,
          onTap: () =>
              _sendEdit(container, terminalId, (b) => _withoutItem(b, item.id)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final container = ref.container;
    final dependsOn = item.dependsOn ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AbListRow(
          horizontalPadding: AbTokens.space16,
          leading: HandlerItemStatusLabel(status: item.status),
          title: Text(item.text, style: AbTokens.sansStyle()),
          // An item's text is bounded at MAX_ITEM_CHARS (400) and reaches it
          // whenever extraction falls back to the raw sentence — a failed judge
          // CLI, a rate-limited account, an agent that cannot judge headless.
          // Nothing else on this row carries the text, so a single clipped line
          // leaves the user reordering and deleting items they cannot read.
          titleMaxLines: 2,
          subtitle: _itemSubtitle(item),
          // The outcome is a sentence the bridge wrote to a length nothing
          // caps, and its verdict is as often at the end as the start
          // ("committed the migration but the push was rejected") — one line
          // clips exactly the half worth reading.
          subtitleMaxLines: 2,
          // Which puts the status word and the menu beside the first line
          // rather than the middle of a two-line block.
          crossAxisAlignment: CrossAxisAlignment.start,
          // Every edit sits behind this menu rather than on the row: a delete
          // one mis-tap away from a scroll would drop work the user asked for.
          trailing: Builder(
            builder: (buttonContext) => AbIconButton(
              icon: AbIcons.more,
              tooltip: 'Item actions',
              onTap: () => _openMenu(buttonContext, container),
            ),
          ),
        ),
        for (final dep in dependsOn)
          _DependencyRow(
            label: labelFor(dep),
            lockReason: lockReason,
            onRemove: () => _sendEdit(
              container,
              terminalId,
              (b) => _withoutDependency(b, item.id, dep),
            ),
          ),
      ],
    );
  }
}

class _DependencyRow extends StatelessWidget {
  const _DependencyRow({
    required this.label,
    required this.lockReason,
    required this.onRemove,
  });

  final ({String text, bool resolved, String? status}) label;

  /// [handlerEditLockReason] for this session, non-null while dropping the
  /// dependency is held.
  final String? lockReason;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space24,
        0,
        AbTokens.space16,
        AbTokens.space4,
      ),
      child: Row(
        children: [
          AbIcon(AbIcons.link, size: 12, color: p.textMuted),
          const SizedBox(width: AbTokens.space6),
          Text(
            'waits on',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
          ),
          const SizedBox(width: AbTokens.space4),
          Expanded(
            child: Text(
              label.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // An unresolved dependency shows the raw id, which is data.
              style: label.resolved
                  ? AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    )
                  : AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    ),
            ),
          ),
          // Named only while it is the thing holding this item up. Any other
          // status leaves the wait self-explanatory, and repeating it here
          // would put a second status column beside every row.
          if (_stallingStatuses.contains(label.status)) ...[
            const SizedBox(width: AbTokens.space6),
            Text(
              label.status!,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: handlerItemStatusColor(p, label.status!),
              ),
            ),
          ],
          // Genuinely disabled while held — dimmed glyph, no hover fill, no
          // focus ring, no click cursor — rather than a disabled tint over a
          // control that still behaves pressable. Nothing is lost by it:
          // [_EditLockNotice] stands above the list for the whole window, so
          // the reason no longer has to ride on this tap.
          AbIconButton(
            icon: AbIcons.close,
            tooltip: lockReason ?? 'Remove this dependency',
            tone: AbIconButtonTone.muted,
            onTap: lockReason == null ? onRemove : null,
          ),
        ],
      ),
    );
  }
}

/// The dead ends [_ItemEditor] can reach, each said where the disabled Save is.
///
/// The first three end the same way, because the sheet holds the only copy of
/// what the user wrote and closing it is what loses it — so every one of them
/// says to take the words first, and none of them offers a retry that would not
/// work.
const _keepYourWords = 'Copy anything you want to keep.';

/// The session went away under the open sheet: auto-disarmed once every item
/// reached a terminal state, or disarmed by the terminal exiting.
const _handlerGoneReason =
    "Handler isn't armed on this session any more, so the edit can't be "
    'saved. $_keepYourWords';

/// The item did, which is the two-client case: the same user's phone deleted it
/// while the desktop was mid-edit.
const _itemGoneReason =
    'This item is no longer on the backlog — it was removed while you were '
    'editing. $_keepYourWords';

/// Neither, as far as the snapshot on screen can tell — the project is no
/// longer warm under the sheet, or the service went down with it. Named by what
/// the user watched happen rather than by a cause this side cannot establish.
const _sendFailedReason = "The edit didn't reach this session. $_keepYourWords";

/// Emptying the field is a deliberate gesture (select all, delete, retype) and
/// the point in it where Save dies is the first keystroke, long before the
/// retype. Delete is named because it is the one way to drop an item, and it is
/// named the same here as on the row.
const _noTextReason =
    'An item needs something to say. To drop it, use Delete on the row.';

/// Rewrites what one item says, in the words the user wanted in the first
/// place. The text on a row is not theirs: extraction splits one sentence into
/// several, rewords each and cuts it at [handlerMaxItemChars], and until this
/// existed the only correction was Delete, retype, and wait out a second
/// extraction — which drops the item's place in the queue and its history with
/// it.
///
/// `condition` is editable HERE AND ONLY where the model already wrote one AND
/// the item can still run. The clause is model-authored and load-bearing in
/// exactly the way the text is: "only if the tests pass" over a sentence the
/// user meant unconditionally is an item that silently never runs, and no other
/// surface can undo it. What this deliberately withholds is AUTHORING a gate
/// where none stands — the same act [HandlerBacklogDrawer] refuses for
/// `dependsOn`, refused for the same reason: a hand-written gate quietly stops
/// work the user asked for, and nothing on this screen would say which one did
/// it. Correcting the model's clause, and clearing it, both move the item
/// towards running; only invention moves it away — and on a [_finishedStatuses]
/// item none of the three moves anything, which is why the field is not there.
///
/// Everything else about the item is the bridge's: id, status, outcome,
/// evidence, ordering and dependencies all survive the edit untouched.
class _ItemEditor extends ConsumerStatefulWidget {
  const _ItemEditor({required this.terminalId, required this.item});

  final String terminalId;
  final HandlerInstructionItem item;

  @override
  ConsumerState<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends ConsumerState<_ItemEditor> {
  late final TextEditingController _text;

  /// Null where there is no clause to correct — the item carries none, or it
  /// has already run and the one it carries can never fire again. The first is
  /// what keeps this sheet from being a place to author a gate; the second
  /// keeps it from offering an edit that changes nothing.
  late final TextEditingController? _condition;

  /// Set by a save the sheet had no way to see coming. Cleared by the next
  /// keystroke, so a service that comes back is one retype away rather than
  /// permanently refused.
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    final text = widget.item.text;
    _text = TextEditingController(text: text)
      // Caret at the end rather than the whole text selected. What stands in
      // this field is model output that is usually most of the way right and
      // wanted one word changed, and select-all makes the first keystroke
      // destroy it.
      ..selection = TextSelection.collapsed(offset: text.length);
    final condition = _trimmedOrNull(widget.item.condition);
    final finished = _finishedStatuses.contains(widget.item.status);
    _condition = condition == null || finished
        ? null
        : TextEditingController(text: condition);
  }

  @override
  void dispose() {
    _text.dispose();
    _condition?.dispose();
    super.dispose();
  }

  /// The clause the save carries: the edited one where the field stands, and
  /// the item's own untouched where it does not — an item with no field is one
  /// whose gate this sheet has no opinion about, not one whose gate it drops.
  String? get _editedCondition {
    final condition = _condition;
    return condition == null
        ? _trimmedOrNull(widget.item.condition)
        : _trimmedOrNull(condition.text);
  }

  bool get _changed =>
      _text.text.trim() != widget.item.text.trim() ||
      _editedCondition != _trimmedOrNull(widget.item.condition);

  /// What stands between the user and a save, or null while nothing does. The
  /// button reads the same answer, so its state and the sentence under it are
  /// one fact rather than two that can disagree — a live Save that does nothing
  /// and a dead one that says nothing are the same bug from opposite sides.
  ///
  /// Ordered by how much the sheet can say: a destination the snapshot shows to
  /// be gone is named exactly, a hold explains itself, and only what neither
  /// accounts for falls through to the refusal a tap discovered.
  String? _saveBlockedReason(
    List<String> pending,
    HandlerSessionState? session,
  ) {
    if (session == null) return _handlerGoneReason;
    if (!session.backlog.any((i) => i.id == widget.item.id)) {
      return _itemGoneReason;
    }
    final lock = handlerEditLockReason(pending);
    if (lock != null) return lock;
    if (_refused) return _sendFailedReason;
    if (_text.text.trim().isEmpty) return _noTextReason;
    return null;
  }

  /// Closes only on a send that happened. This is the one edit carrying
  /// something the user cannot get back by repeating the gesture, so every
  /// refusal leaves the sheet standing with their words in it and answers in
  /// the same rebuild — [_saveBlockedReason] is where that answer is written.
  void _save() {
    final result = _sendEdit(
      ref.container,
      widget.terminalId,
      (b) => _withItemRetexted(
        b,
        widget.item.id,
        text: _text.text.trim(),
        condition: _editedCondition,
      ),
    );
    if (result == _EditSend.sent) {
      Navigator.of(context).maybePop();
      return;
    }
    // Every refusal [_saveBlockedReason] can see has already taken Save out of
    // reach, so a tap that gets here found something the snapshot on screen
    // does not have: a project invalidated under the sheet leaves the last one
    // standing, which is what makes this the only report of it.
    setState(() => _refused = true);
  }

  void _onEdited() => setState(() => _refused = false);

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final state = ref.watch(handlerStateProvider).value;
    final pending =
        state?.pendingInstructionsFor(widget.terminalId) ?? const <String>[];
    final blocked = _saveBlockedReason(
      pending,
      state?.sessions[widget.terminalId],
    );
    final condition = _condition;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            'Edit item',
            onClose: () => Navigator.of(context).maybePop(),
          ),
        ),
        // The fields are the only part that gives. On a phone the sheet gets
        // the screen minus the keyboard, and a fallback item at six lines plus
        // a condition asks for more than that leaves — so what a user is in the
        // middle of scrolls, and the title saying where they are and the row
        // saying how to leave both stay put.
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AbTokens.space16,
                    AbTokens.space8,
                    AbTokens.space16,
                    0,
                  ),
                  child: _CappedField(
                    controller: _text,
                    // Opens at the two lines the row itself renders, so an item
                    // is the same shape here as where it was tapped, and grows
                    // to six before scrolling inside itself — a fallback item
                    // runs to [handlerMaxItemChars], and a field that grew that
                    // far would leave the sheet nothing but field.
                    minLines: 2,
                    maxLines: 6,
                    autofocus: true,
                    onChanged: (_) => _onEdited(),
                  ),
                ),
                if (condition != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AbTokens.space16,
                      AbTokens.space10,
                      AbTokens.space16,
                      AbTokens.space4,
                    ),
                    // The row's own words for this clause, so the gate is named
                    // the same thing where it is read and where it is changed.
                    child: Text(
                      'Runs only if',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AbTokens.space16,
                    ),
                    child: _CappedField(
                      controller: condition,
                      minLines: 1,
                      maxLines: 3,
                      onChanged: (_) => _onEdited(),
                    ),
                  ),
                  // Emptying the field is the un-gating act, and the one edit on
                  // this sheet whose effect is invisible in what it leaves
                  // behind. So it is answered at the moment it happens, and
                  // never before.
                  if (_editedCondition == null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AbTokens.space16,
                        AbTokens.space4,
                        AbTokens.space16,
                        0,
                      ),
                      child: Text(
                        'No condition — the item runs whenever its turn comes.',
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontXs,
                          color: p.textMuted,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        // Beside the button it explains rather than above the fields, and never
        // inside the part that scrolls: a reason the user has to go looking for
        // is a reason they meet after the second tap.
        if (blocked != null) _EditLockNotice(reason: blocked),
        const SizedBox(height: AbTokens.space16),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            0,
            AbTokens.space16,
            AbTokens.space16,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(
                label: 'Cancel',
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: AbTokens.space8),
              // Off while anything blocks the save, and off until there is
              // something to save. Only the second half goes unsaid: a Save
              // that would save nothing is read as done rather than as broken,
              // and a wholesale replace that changes nothing costs a round trip
              // to leave the list exactly where it stands.
              AbButton(
                label: 'Save item',
                variant: AbButtonVariant.primary,
                onTap: blocked == null && _changed ? _save : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A field bounded at [handlerMaxItemChars], and the only thing this sheet says
/// about that bound: how much room is left, once running out is close enough to
/// matter.
///
/// A standing counter would sit on every edit to tell almost none of them
/// anything — the items that reach the cap are the extractor's raw-sentence
/// fallbacks, a small share of any list. Saying nothing at all is worse: the
/// formatter simply stops accepting keystrokes, which is the shape a user
/// reports as a broken field.
class _CappedField extends StatelessWidget {
  const _CappedField({
    required this.controller,
    required this.onChanged,
    required this.minLines,
    required this.maxLines,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final int minLines;
  final int maxLines;
  final bool autofocus;

  /// Roughly a short clause — far enough out that the warning arrives while
  /// there is still room to finish a thought in.
  static const _warnWithin = 40;

  @override
  Widget build(BuildContext context) {
    // Counted the way [LengthLimitingTextInputFormatter] counts, in grapheme
    // clusters: a field that stopped at 400 while a counter still promised room
    // would be the broken-field report this line exists to prevent.
    final left = handlerMaxItemChars - controller.text.characters.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AbTextField(
          controller: controller,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          inputFormatters: [
            LengthLimitingTextInputFormatter(handlerMaxItemChars),
          ],
          onChanged: onChanged,
        ),
        if (left <= _warnWithin)
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space4),
            child: Text(
              left == 1 ? '1 character left' : '$left characters left',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}
