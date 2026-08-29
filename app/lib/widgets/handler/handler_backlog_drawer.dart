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
import '../../providers/providers.dart';
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
    final session = ref.watch(handlerStateProvider).value?.sessions[terminalId];
    final backlog = session?.backlog ?? const <HandlerInstructionItem>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            'Backlog',
            onClose: () => Navigator.of(context).maybePop(),
          ),
        ),
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
        const SizedBox(height: AbTokens.space8),
        Flexible(
          child: backlog.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AbTokens.space16,
                    vertical: AbTokens.space24,
                  ),
                  child: AbEmptyState.compact(
                    title: session == null
                        ? 'Handler is not armed on this session.'
                        : 'Nothing queued — what you ask for lands here.',
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: backlog.length,
                  itemBuilder: (_, index) => _BacklogRow(
                    terminalId: terminalId,
                    item: backlog[index],
                    canMoveUp: index > 0,
                    canMoveDown: index < backlog.length - 1,
                    labelFor: (id) => _dependencyLabel(backlog, id),
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
  void _instruct(String text) {
    if (text.trim().isEmpty) return;
    focusedServiceOrNull(
      ref.container,
      (s) => s.handlerService,
    )?.instruct(widget.terminalId, text);
  }

  void _submitTyped() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _instruct(text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      padding: const EdgeInsets.only(top: AbTokens.space8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: AbTokens.rowHeightSm,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AbTokens.space16),
              child: Row(
                children: [
                  for (final (i, preset)
                      in handlerPresetInstructions.indexed) ...[
                    if (i > 0) const SizedBox(width: AbTokens.space14),
                    AbChip.label(
                      label: preset,
                      color: p.textSecondary,
                      size: AbChipSize.md,
                      onTap: () => _instruct(preset),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbTokens.space16,
              0,
              AbTokens.space16,
              AbTokens.space8,
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
        ],
      ),
    );
  }
}

/// Handler acts first and is read hours later, so there is no review step in
/// which the undo path (spec §5.2) could be stumbled upon at the moment it is
/// wanted — this puts it in front of the user beforehand. It makes undo
/// discoverable; it does not make a bad outcome less likely.
class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space8,
      ),
      child: Text(
        handlerDisclaimerText,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXxs,
          color: p.textMuted,
        ),
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

/// Sends [edit] applied to the FRESHEST backlog readable at the moment of the
/// tap. `handler:configure` replaces the bridge's list wholesale with no merge,
/// and extraction appends to it asynchronously behind the handoff, so an edit
/// derived from anything older silently deletes whatever landed in between —
/// which is also why the edited list is never held across an await.
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

class _BacklogRow extends ConsumerWidget {
  const _BacklogRow({
    required this.terminalId,
    required this.item,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.labelFor,
  });

  final String terminalId;
  final HandlerInstructionItem item;
  final bool canMoveUp;
  final bool canMoveDown;
  final ({String text, bool resolved, String? status}) Function(String id)
  labelFor;

  /// Whether something this item waits on is itself stalled, which is what
  /// decides between the two ways out of `blocked`.
  bool get _waitsOnStalledWork => (item.dependsOn ?? const <String>[]).any(
    (id) => _stallingStatuses.contains(labelFor(id).status),
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
        // away.
        if (canMoveUp) ...[
          // Offered without its mirror. The queue runs from the top, so lifting
          // an item ahead is a change that holds, while sending one to the
          // bottom is undone by the next instruction — extraction appends.
          AbMenuItem(
            label: 'Move to top',
            icon: AbIcons.moveToTop,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemAtTop(b, item.id),
            ),
          ),
          AbMenuItem(
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
          AbMenuItem(
            label: 'Move down',
            icon: AbIcons.arrowDown,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemMoved(b, item.id, 1),
            ),
          ),
        if (_requeueableStatuses.contains(item.status) && !_waitsOnStalledWork)
          AbMenuItem(
            label: 'Requeue',
            icon: AbIcons.refresh,
            onTap: () => _sendEdit(
              container,
              terminalId,
              (b) => _withItemRequeued(b, item.id),
            ),
          ),
        const AbMenuDivider(),
        AbMenuItem(
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
  const _DependencyRow({required this.label, required this.onRemove});

  final ({String text, bool resolved, String? status}) label;
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
          AbIconButton(
            icon: AbIcons.close,
            tooltip: 'Remove this dependency',
            tone: AbIconButtonTone.muted,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}
