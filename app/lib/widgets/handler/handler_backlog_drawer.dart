import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_chip.dart';
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
import 'handler_item_status.dart';

/// The 1-tap presets (spec §4.2). Each label is verbatim the instruction the
/// chip sends: a chip is exactly the sentence the user would have typed, which
/// is what keeps it on the same authorization path as typed text. Keeping label
/// and payload one string is what stops the two drifting apart.
const handlerPresetInstructions = <String>[
  'Run Tests',
  'Commit',
  'Create PR',
  'Clean Build',
];

/// What the sheet is called, and what it is called for. The surface keeps its
/// own name first: a card, a menu entry and the pill all send the user here by
/// the word "backlog", and a title that led with the session would rename the
/// destination halfway through the trip.
String _backlogTitle(String? sessionName) =>
    sessionName == null ? 'Backlog' : 'Backlog · $sessionName';

/// Verbatim from spec §5.5 — the wording is the spec's, not a paraphrase.
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
/// Deliberately offers no way to CREATE a dependency (spec §3.3): the bridge
/// derives `dependsOn` from the user's own ordering words, and a hand-authored
/// one silently blocks work they asked for.
class HandlerBacklogDrawer extends ConsumerWidget {
  const HandlerBacklogDrawer({super.key, required this.terminalId});

  final String terminalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final state = ref.watch(handlerStateProvider).value;
    final session = state?.sessions[terminalId];
    final backlog = session?.backlog ?? const <HandlerInstructionItem>[];
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
                    notifyOnly: session?.notifyOnly ?? false,
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
                          labelFor: (id) => _dependencyLabel(backlog, id),
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
/// doing anything at all. It offers no button: the presets and the field are
/// already on screen under this list, and a second route to one action is how
/// one action ends up with two names.
///
/// [hasGoal] is what stops the invitation reading as "nothing was received".
/// The goal stands above this list and the bridge extracts items from it, so a
/// user told to add what they want done would retype the sentence they started
/// the session with — and the extraction that is already running appends it a
/// second time. Naming the goal instead invites what is genuinely missing.
class _NothingQueued extends StatelessWidget {
  const _NothingQueued({
    required this.armed,
    required this.notifyOnly,
    required this.hasGoal,
  });

  /// False for a terminal Handler was never armed on — a state with no
  /// invitation to make, since nothing here would receive it.
  final bool armed;

  /// A notify-only session escalates every pause and injects nothing, so this
  /// list is one the user works through themselves. Saying otherwise is the
  /// single biggest thing this surface can be wrong about.
  final bool notifyOnly;

  /// Whether a goal is stated above this list.
  final bool hasGoal;

  @override
  Widget build(BuildContext context) => armed
      ? AbEmptyState(
          title: hasGoal
              ? 'Nothing queued beyond the goal above.'
              : "Add what you want done while you're away.",
          subtitle: notifyOnly
              ? 'Notify only on this session — every pause comes to you, and '
                    'nothing here is acted on while you are away.'
              : 'Handler already answers what the agent pauses on. A backlog '
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

/// Presets and the free-text field, here rather than pinned above the composer.
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

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Preset chips and typed text land here alike: one path, one message type,
  /// so a rule that later applies to instructions cannot miss the chips
  /// (spec §5.4).
  ///
  /// Resolved through the container for the same reason [_sendEdit] is: this
  /// fires from a tap inside a sheet, which the send itself may pop.
  ///
  /// The service owns both the empty check and the debounce, so a chip and the
  /// field are refused on the same terms; this only decides what the user is
  /// told about it. A blank field is silent — there was nothing to send and
  /// the user knows it — while a duplicate is a send that looked identical to
  /// one that worked and did not happen, on the primary action of the surface.
  HandlerInstructResult _instruct(String text) {
    final result =
        focusedServiceOrNull(
          ref.container,
          (s) => s.handlerService,
        )?.instruct(widget.terminalId, text) ??
        HandlerInstructResult.empty;
    setState(() {
      _held = result == HandlerInstructResult.duplicate ? text.trim() : null;
    });
    return result;
  }

  void _submitTyped() {
    // Cleared only on a send that happened: a refused one would take the
    // user's words with it and leave an empty field beside an unchanged list.
    if (_instruct(_input.text) != HandlerInstructResult.sent) return;
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final held = _held;
    final outstanding =
        ref
            .watch(handlerStateProvider)
            .value
            ?.pendingInstructionsFor(widget.terminalId) ??
        const <String>[];
    final stillHeld = held != null && outstanding.contains(held) ? held : null;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      padding: const EdgeInsets.only(top: AbTokens.space8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Wrapped, not scrolled. Four md chips overrun a narrow phone by
          // roughly one label, and a strip that scrolls says so only to
          // someone who already drags it — so the last preset was reachable
          // only by accident, on the fastest route this sheet has to a useful
          // backlog. A second run costs one row on the widths that need it and
          // nothing on the widths that don't.
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space16,
              vertical: AbTokens.space10,
            ),
            child: Wrap(
              spacing: AbTokens.space14,
              runSpacing: AbTokens.space10,
              children: [
                for (final preset in handlerPresetInstructions)
                  AbChip.label(
                    label: preset,
                    color: p.textSecondary,
                    size: AbChipSize.md,
                    onTap: () => _instruct(preset),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              AbTokens.space16,
              0,
              AbTokens.space16,
              stillHeld == null ? AbTokens.space8 : AbTokens.space4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: AbTextField(
                    controller: _input,
                    hintText: 'Add an instruction…',
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submitTyped(),
                  ),
                ),
                const SizedBox(width: AbTokens.space6),
                AbIconButton(
                  icon: AbIcons.send,
                  tooltip: 'Add to backlog',
                  onTap: _submitTyped,
                ),
              ],
            ),
          ),
          // Answered where the send was made, and in the same verb the field,
          // the button and the waiting row all use. Without it a held duplicate
          // moves nothing on screen: the field keeps the user's words, the list
          // is unchanged, and the tail row saying so may be scrolled away —
          // which is a broken button, not a debounce.
          if (stillHeld != null)
            // Full width so the line starts on the field's own left edge; the
            // column around it centres anything that sizes to its child.
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
                  'Already adding "${_quoted(stillHeld)}".',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Handler acts first and is read hours later, so there is no review step in
/// which the undo path (spec §5.2) could be stumbled upon at the moment it is
/// wanted — this puts it in front of the user beforehand. It makes undo
/// discoverable; it does not make a bad outcome less likely.
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
  List<HandlerInstructionItem> backlog,
  String id,
) {
  for (final i in backlog) {
    if (i.id == id) return (text: i.text, resolved: true, status: i.status);
  }
  return (text: id, resolved: false, status: null);
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
    return 'Still adding ${pending.length} instructions — editing is paused '
        'until they land.';
  }
  return 'Still adding "${_quoted(pending.single)}" — editing is paused '
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
        // A step brighter than the progress line above it, and no louder: the
        // list is held because the user asked for something, not because
        // anything is wrong.
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
/// [HandlerSessionState.notifyOnly] rides along from that same snapshot: it is
/// required on the wire, and a guessed value flips the session between
/// notifying and acting without saying so.
///
/// Takes the container rather than a `WidgetRef` because a menu entry fires
/// after its route pops, by which time a status update may have taken this row
/// out of the tree.
void _sendEdit(
  ProviderContainer container,
  String terminalId,
  List<HandlerInstructionItem> Function(List<HandlerInstructionItem>) edit,
) {
  final service = focusedServiceOrNull(container, (s) => s.handlerService);
  if (service == null) return;
  final session = service.currentState.sessions[terminalId];
  if (session == null) return;
  service.updateBacklog(
    terminalId: terminalId,
    backlog: edit(session.backlog),
    notifyOnly: session.notifyOnly,
  );
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

  Future<void> _openMenu(
    BuildContext context,
    ProviderContainer container,
  ) async {
    final anchor = abMenuAnchorRect(context);
    if (anchor == null) return;
    await showAbMenu<void>(
      context: context,
      anchorRect: anchor,
      preferred: AbMenuPlacement.above,
      width: 200,
      entries: [
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
