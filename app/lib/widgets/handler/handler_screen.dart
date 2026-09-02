import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_progress_rule.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_state_chip.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import 'handler_backlog_drawer.dart';
import 'handler_blocked_action_card.dart';
import 'handler_decision_card.dart';
import 'handler_item_status.dart';
import 'handler_layout.dart';
import 'handler_reply_sheet.dart';
import 'handler_session_settings.dart';

/// Day-aware, not a bare clock: this feed is written while the user is away and
/// read afterwards, so it routinely spans midnight.
String _fmtTime(int epochMs) =>
    dayAwareTime(DateTime.fromMillisecondsSinceEpoch(epochMs));

class HandlerScreen extends ConsumerWidget {
  const HandlerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _body(context, ref, ref.watch(focusedSessionHandlerStateProvider));
  }

  Widget _body(BuildContext context, WidgetRef ref, HandlerState state) {
    final p = context.antgrid;

    // Undo offers and wrap-up reports keep this screen alive after the last
    // disarm: a wrapped-up session is exactly when the force push it made at
    // 3am — and the account of what it did — get read.
    //
    // Escalations are in the test for a different reason: they arrive on their
    // own stream, so a pushed one can land before the status frame that adds
    // its session, and `anyArmed` alone would answer an unanswered question
    // with the arm CTA.
    if (!state.anyArmed &&
        state.escalations.isEmpty &&
        state.snapshots.isEmpty &&
        state.wrapUps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AbTokens.space24),
        child: Center(
          child: AbEmptyState(
            icon: AbIcons.shield,
            title: 'Handler is off for this session',
            subtitle:
                'Arm it with the shield at the end of the top bar. It then '
                'watches this session, answers what it can, and escalates the '
                'rest to you here. This tab answers for one session — '
                'another that needs you is counted on its own agent header.',
          ),
        ),
      );
    }

    final service = serviceWhenReady(ref, handlerServiceProvider);
    final container = ref.container;

    // No catalog prediction here on purpose: every row on this screen is an
    // ARMED session, and the bridge's own per-session observability describes
    // its live mode and judge pick. The pre-arm guess belongs where nothing is
    // armed yet (the header's shield tooltip).

    Future<void> answer(HandlerEscalation e) async {
      if (service == null) return;
      if (e.kind == 'resolve_in_session') {
        // Option-based prompt — the chat transcript owns the resolution UI
        // (permission card / question form); focusing the session gets the
        // user there instead of collecting free text that can't answer it.
        // Switching focus is not enough on mobile: this screen is the workspace
        // page and the transcript is the agent page, so without the swipe the
        // tap looks like it did nothing. Desktop shows both, and switching to
        // the agent page there is a no-op.
        ref.read(activeSessionIdProvider.notifier).set(e.terminalId);
        ref.read(switchToAgentProvider)?.call();
        return;
      }
      final text = await showHandlerReplySheet(context, e);
      if (text == null) return;
      // Re-resolved after the sheet, exactly like onDisarm below: the sheet stays open
      // for as long as the user types, and the focused project's session can be rebuilt
      // in that window. The build-time instance would be disposed by then, and
      // `reply` answers a disposed service with `false` — an answer the user typed,
      // silently dropped, under a card that still reads as answered.
      focusedServiceOrNull(container, (s) => s.handlerService)?.reply(e, text);
    }

    // Confirmed for one action out of four. Undoing a hard reset, a recursive
    // delete or a clean touches this machine only; undoing a force push writes
    // to a shared remote, and the row it is offered on is a scrolling list row
    // whose whole body is the tap target, because the snapshot buys prevention
    // back as one tap.
    // The dialog is the only thing standing between a thumb landing where the
    // scroll stopped and a ref overwritten for everyone on it.
    //
    // Re-resolved after the dialog for the same reason `answer` re-resolves
    // after its sheet: the focused project's session can be rebuilt while the
    // dialog is open, and the build-time instance is disposed by then.
    Future<void> undo(HandlerSnapshot s) async {
      if (s.action == 'force_push') {
        final ok = await AbConfirmDialog.show(
          context: context,
          title: 'Undo this force push?',
          // No promise of recovery: the bridge pins the current remote tip
          // before overwriting it, but only when the ref still exists there —
          // a ref already gone from the remote is restored with a bare
          // `--force` and nothing pinned (snapshot.ts).
          body:
              'This force-pushes the remote back to where it was before the '
              "agent's push. Whatever is on it now is overwritten.\n\n"
              '${s.summary}',
          confirmLabel: 'Undo force push',
          destructive: true,
        );
        if (!ok) return;
      }
      focusedServiceOrNull(container, (x) => x.handlerService)?.undo(s);
    }

    // `urgent` rides the meta column rather than each row's own body: an
    // escalation renders as one of three unrelated widgets (blocked card,
    // decision card, plain row) and this is the only piece all three share, so
    // it is the only place the marker cannot be added to two of them and
    // forgotten on the third.
    Widget meta(int at, {bool urgent = false}) =>
        _RowMeta(at: at, p: p, urgent: urgent);

    // The urgency test itself, once, for that same reason: spelled out at each
    // of the three call sites it is three chances to omit, and a fourth row
    // shape starts life without it.
    Widget escalationMeta(HandlerEscalation e) =>
        meta(e.at, urgent: e.urgency == 'high');

    return CustomScrollView(
      slivers: [
        // Actionable first. The old order opened with the session headers, so
        // two armed sessions carrying a backlog each pushed the one section the
        // user came here to act on several hundred pixels down the list.
        if (state.escalations.isNotEmpty) ...[
          _section('Needs you', state.escalations.length, p.accent, p),
          SliverList.list(
            children: [
              for (final e in state.escalations)
                // First in the chain, and a cheap floor rather than a live
                // case: the bridge never mints choices for a report, so this
                // and the decision card can never both want the row.
                if (e.kind == 'guard_blocked')
                  HandlerBlockedActionCard(
                    escalation: e,
                    trailing: escalationMeta(e),
                    // Re-resolved through the container for the same reason
                    // `answer` re-resolves after its sheet: the build-time
                    // instance can be disposed by the time a tap lands.
                    onDismiss: service == null
                        ? null
                        : () => focusedServiceOrNull(
                            container,
                            (s) => s.handlerService,
                          )?.dismiss(e),
                    onReply: service == null ? null : () => answer(e),
                  )
                else if (e.choices != null)
                  HandlerDecisionCard(
                    escalation: e,
                    trailing: escalationMeta(e),
                    // The id, not the choice: the service resolves it against
                    // the escalation's own offered set, so the text on the wire
                    // is always the one the bridge authored.
                    onChoice: service == null
                        ? null
                        : (choiceId) => service.answerWithChoice(e, choiceId),
                    onCustomReply: service == null ? null : () => answer(e),
                  )
                else
                  AbListRow(
                    leading: HandlerRail(
                      icon: e.floorRule != null ? AbIcons.shield : null,
                      color: p.warning,
                    ),
                    // The question is the thing being decided, so it is allowed
                    // the room to be read. Clipped at one line it was a decision
                    // taken without its subject.
                    titleMaxLines: 3,
                    subtitleMaxLines: 2,
                    // Top-aligned because the title wraps: centred, the shield
                    // drifts down past the question it qualifies and lands
                    // beside the reasoning, while the decision card directly
                    // above keeps its own shield on the first line.
                    crossAxisAlignment: CrossAxisAlignment.start,
                    title: Text(
                      e.question,
                      style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (e.floorRule != null)
                          Text(
                            'Safety floor: ${e.floorRule}',
                            style: AbTokens.sansStyle(
                              fontSize: AbTokens.fontXs,
                              fontWeight: FontWeight.w600,
                              color: p.warning,
                            ),
                          ),
                        Text(
                          e.reasoning,
                          style: AbTokens.sansStyle(
                            fontSize: AbTokens.fontXs,
                            color: p.textMuted,
                          ),
                        ),
                      ],
                    ),
                    trailing: escalationMeta(e),
                    onTap: () => answer(e),
                  ),
            ],
          ),
        ],
        if (state.sessions.isNotEmpty) ...[
          // Section headers here are PINNED, so the band left standing over a
          // headerless section is the previous one — drop this and the session
          // card scrolls up under "NEEDS YOU", reading as an unanswered
          // escalation.
          _section('Session', null, p.textMuted, p),
          SliverList.list(
            children: [
              for (final s in state.sessions.values)
                _SessionCard(
                  session: s,
                  // Through the shared resolver, which carries the session-list
                  // subscription its own read needs — resolving off the service
                  // directly here would pin whatever the list said on first
                  // build. The bare state.defaultTool is NOT a second
                  // resolution rule: it only fires while the service is still
                  // resolving (the resolver already includes it when the
                  // service is up).
                  judgeLabel:
                      handlerEffectiveJudge(ref, s.terminalId, s.judgeTool) ??
                      state.defaultTool ??
                      'default',
                  // Resolved at tap time, not captured here: this fires from a
                  // menu entry that runs after its route pops, and the focused
                  // project's session can be rebuilt while that menu is open
                  // (host restart, eviction, connection retry). The build-time
                  // instance would be disposed by then and swallow the disarm.
                  onDisarm: () => focusedServiceOrNull(
                    container,
                    (s) => s.handlerService,
                  )?.disarm(s.terminalId),
                  onOpenSettings: () => detached(
                    'HandlerScreen',
                    'open session settings',
                    () =>
                        showHandlerSessionSettingsSheet(context, s.terminalId),
                  ),
                  onOpenBacklog: () => unawaited(
                    showHandlerBacklogDrawer(context, s.terminalId),
                  ),
                ),
            ],
          ),
        ],
        // Below Sessions because a report is not an action, and directly above
        // Undo because its last line points at that section.
        if (state.wrapUps.isNotEmpty) ...[
          _section('Wrap-up', state.wrapUps.length, p.textMuted, p),
          SliverList.builder(
            itemCount: state.wrapUps.length,
            itemBuilder: (_, i) {
              final w = state.wrapUps[state.wrapUps.length - 1 - i];
              return _WrapUpCard(
                wrapUp: w,
                meta: meta(w.at),
                // Derived, never read off the record: an undo taken after the
                // wrap-up spends its entry and a re-arm retires the offers
                // outright, so a count frozen at compose time is a lie on the
                // one surface built to be read hours later. This is the same
                // list the Undo section below renders, so the two cannot
                // disagree.
                openUndos: state.snapshots
                    .where((s) => s.terminalId == w.terminalId && !s.undone)
                    .length,
                p: p,
              );
            },
          ),
        ],
        if (state.snapshots.isNotEmpty) ...[
          _section('Undo', state.snapshots.length, p.warning, p),
          // Lazy for the same reason the activity feed below is: the store keeps up
          // to MAX_STORED offers and every flagged inject re-sends its row.
          SliverList.builder(
            itemCount: state.snapshots.length,
            itemBuilder: (_, i) {
              final s = state.snapshots[state.snapshots.length - 1 - i];
              return _SnapshotRow(
                snapshot: s,
                meta: meta(s.at),
                pending: state.pendingUndo.contains(s.snapshotId),
                onUndo: () =>
                    detached('HandlerScreen', 'undo snapshot', () => undo(s)),
                p: p,
              );
            },
          ),
        ],
        _section('Activity', null, p.textMuted, p),
        if (state.activity.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: handlerGutter,
                vertical: AbTokens.space16,
              ),
              child: Text(
                'No activity yet.',
                style: AbTokens.sansStyle(color: p.textMuted),
              ),
            ),
          )
        else
          // Built lazily, unlike the ListView this replaced: the feed is capped
          // at 200 rows and a new one arrives on every judge decision, so
          // constructing all of them per message was a cost paid continuously.
          SliverList.builder(
            itemCount: state.activity.length,
            itemBuilder: (_, i) {
              final a = state.activity[i];
              return _ActivityRow(record: a, meta: meta(a.at), p: p);
            },
          ),
      ],
    );
  }

  /// Pinned, because the activity feed runs to 200 rows and a boundary that
  /// scrolls away takes with it the only thing saying which section the row
  /// under the user's thumb belongs to.
  Widget _section(String label, int? count, Color color, AbColors p) =>
      AbSliverSectionHeader(
        label: label,
        count: count,
        color: color,
        background: p.bgDeep,
        padding: const EdgeInsets.symmetric(horizontal: handlerGutter),
      );
}

/// Right-aligned time metadata shown on escalation and activity rows.
class _RowMeta extends StatelessWidget {
  const _RowMeta({required this.at, required this.p, this.urgent = false});
  final int at;
  final AbColors p;

  /// Only escalations pass this. Snapshots and activity rows are history, and
  /// nothing about them is waiting on the user.
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final style = AbTokens.monoStyle(
      fontSize: AbTokens.fontXxs,
      color: p.textMuted,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Above the timestamp, so the eye reaches it on the way down rather
        // than after it. System-assigned data, so the mono uppercase chip,
        // matching ESCALATE ONLY on the session card.
        if (urgent) AbChip.system(label: 'URGENT', color: p.warning),
        Text(_fmtTime(at), style: style),
      ],
    );
  }
}

/// The part of a park the run-state word can't carry: why it stopped, and when
/// it comes back. Absolute rather than a countdown — the card is read hours
/// after it was written, and a ticking clock on a scrolling log is a repaint
/// per second for information a wall time already gives.
///
/// Day-aware, matching the header pill: a rate limit that resets at 05:00
/// tomorrow read as a bare `05:00` tonight is a deadline already blown.
///
/// A deadline behind us means the resume is in flight, not that the session is
/// overdue — the same rule `handlerPaStatusLabel` follows, so the bar and this
/// card never disagree about a park. [now] is injectable for that reason.
String? handlerParkNote(HandlerSessionState session, {DateTime? now}) {
  if (session.runState != HandlerRunState.parked) return null;
  final reason = switch (session.parkKind) {
    'limit' => 'rate limit',
    'outage' => 'provider outage',
    _ => null,
  };
  final until = session.parkedUntil;
  final ref = now ?? DateTime.now();
  final wake = until == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(until);
  final parts = [
    ?reason,
    if (wake != null)
      wake.isAfter(ref)
          ? 'resumes ${dayAwareTime(wake, now: ref)}'
          : 'resuming',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// One armed session, read top-down as: what it is doing, what it is working
/// towards, how far along, and what is left.
///
/// The run state leads, because it is the first thing anyone asks of a tab
/// named Handler and the title-bar pill that also carries it is nowhere near
/// this panel.
///
/// Only the status line's own two ends are fixed — the run-state word and the
/// Armed chip. Everything else that could grow (the judge name) either shrinks
/// or sits on a line below, so a narrow context panel or a scaled text size
/// cannot overflow the row.
class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.judgeLabel,
    required this.onDisarm,
    required this.onOpenSettings,
    required this.onOpenBacklog,
  });
  final HandlerSessionState session;

  /// Resolved judge CLI, rendered read-only on the status line (override, else
  /// the session's default). This never mutates it.
  final String judgeLabel;
  final VoidCallback onDisarm;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenBacklog;

  // Only the first few items render inline — a stacking session can hold dozens
  // and the card must stay a card, not push the "needs you" rows off screen.
  // The rest are one tap away on the progress row.
  static const _maxItemRows = 5;

  /// Disarm behind a menu rather than on the chip itself. The chip states what
  /// IS ("Armed"), so a tap that silently turned Handler off would be a control
  /// whose label contradicts its effect — and this one sits a mis-tap away from
  /// a scrolling list.
  Future<void> _openArmedMenu(BuildContext context) async {
    final anchor = abMenuAnchorRect(context);
    if (anchor == null) return;
    await showAbMenu<void>(
      context: context,
      anchorRect: anchor,
      entries: [
        AbMenuItem(
          label: 'Handler settings',
          icon: AbIcons.settings,
          onTap: onOpenSettings,
        ),
        AbMenuItem(
          label: 'Disarm Handler',
          icon: AbIcons.shield,
          danger: true,
          onTap: onDisarm,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final hiddenItems = session.backlogTotal - _maxItemRows;
    final visibleItems = hiddenItems > 0
        ? session.backlog.sublist(0, _maxItemRows)
        : session.backlog;
    final runStateColor = handlerRunStateColor(p, session.runState);
    final parkNote = handlerParkNote(session);
    final mutedMono = AbTokens.monoStyle(
      fontSize: AbTokens.fontXxs,
      color: p.textMuted,
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: handlerGutter,
        vertical: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Empty on purpose: this card carries no conditional glyph, but
              // it shares a list with rows that do, and the reserved slot is
              // what puts every title on one column.
              const HandlerRail(),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      handlerRunStateLabel(session.runState),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        fontWeight: FontWeight.w600,
                        color: runStateColor,
                      ),
                    ),
                    const SizedBox(width: AbTokens.space6),
                    // The only child of this row allowed to grow, so it is also
                    // the only one that has to give way. The judge CLI is a
                    // bare tool name with nothing beside it to say so — the
                    // tooltip is what names the column.
                    Flexible(
                      child: AbTooltip(
                        message: 'Judge',
                        child: Text(
                          judgeLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mutedMono,
                        ),
                      ),
                    ),
                    // Beside the judge name because that is what it qualifies:
                    // the named judge cannot run headless, so nothing it sees
                    // gets answered without the user.
                    if (session.observability ==
                        HandlerObservability.escalateOnly) ...[
                      const SizedBox(width: AbTokens.space6),
                      AbTooltip(
                        message: escalateOnlyNotice,
                        child: AbChip.system(
                          label: 'ESCALATE ONLY',
                          color: p.warning,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              Builder(
                builder: (chipContext) => AbStateChip(
                  icon: AbIcons.shield,
                  label: 'Armed',
                  tone: p.accent,
                  active: true,
                  tooltip: 'Handler is armed on this session',
                  onTap: (_) => unawaited(_openArmedMenu(chipContext)),
                ),
              ),
            ],
          ),
          // Everything under the status line hangs off it rather than off the
          // card edge, so the card reads as one session.
          Padding(
            padding: const EdgeInsets.only(left: handlerRailInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (parkNote != null)
                  Text(
                    parkNote,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.warning,
                    ),
                  ),
                // Only ever rendered from the session's OWN report: a bridge
                // that sends no observability leaves this silent rather than
                // guessing from the agent it happens to run.
                if (session.observability ==
                    HandlerObservability.unsupported) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AbIcon(AbIcons.warning, size: 12, color: p.warning),
                      const SizedBox(width: AbTokens.space4),
                      Expanded(
                        child: Text(
                          'Not watched — this agent reports nothing the '
                          'Handler can act on.',
                          style: AbTokens.sansStyle(
                            fontSize: AbTokens.fontXs,
                            color: p.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AbTokens.space2),
                Text(
                  // A 1-tap arm legitimately has no goal until extraction
                  // resolves behind the handoff, so this is a normal state, and
                  // reads as one: an absence must not be the loudest text on
                  // the panel.
                  session.goal.isEmpty ? 'No goal yet' : session.goal,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: session.goal.isEmpty
                      ? AbTokens.sansStyle(
                          fontSize: AbTokens.fontSm,
                          color: p.textMuted,
                        )
                      : AbTokens.sansStyle(fontWeight: FontWeight.w600),
                ),
                if (session.backlogTotal > 0)
                  _BacklogSummary(
                    session: session,
                    visibleItems: visibleItems,
                    hiddenItems: hiddenItems,
                    onTap: onOpenBacklog,
                    p: p,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress, the first few items, and the way through to the rest.
///
/// The whole block is the tap target: "… 3 more" used to be inert text, which
/// left the Handler tab with no route to the full stack at all.
class _BacklogSummary extends StatelessWidget {
  const _BacklogSummary({
    required this.session,
    required this.visibleItems,
    required this.hiddenItems,
    required this.onTap,
    required this.p,
  });
  final HandlerSessionState session;
  final List<HandlerInstructionItem> visibleItems;
  final int hiddenItems;
  final VoidCallback onTap;
  final AbColors p;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AbTokens.space8),
            AbProgressRule(
              fraction: session.backlogTotal == 0
                  ? 0
                  : session.backlogDone / session.backlogTotal,
            ),
            const SizedBox(height: AbTokens.space6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    handlerProgressLabel(session),
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                // The overflow count rides next to the affordance that reveals
                // it, not buried at the end of the progress sentence.
                if (hiddenItems > 0) ...[
                  Text(
                    '$hiddenItems more',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textMuted,
                    ),
                  ),
                  const SizedBox(width: AbTokens.space4),
                ],
                AbIcon(AbIcons.chevronRight, size: 12, color: p.textMuted),
              ],
            ),
            for (final item in visibleItems) ...[
              const SizedBox(height: AbTokens.space4),
              _BacklogItemRow(item: item, p: p),
            ],
          ],
        ),
      ),
    );
  }
}

/// One backlog item: its status, then the user's own words for it.
class _BacklogItemRow extends StatelessWidget {
  const _BacklogItemRow({required this.item, required this.p});
  final HandlerInstructionItem item;
  final AbColors p;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HandlerItemStatusLabel(status: item.status),
        const SizedBox(width: AbTokens.space6),
        Expanded(
          child: Text(
            item.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            // The item is the content of this block, not a caption on it: what
            // the session was asked to do is the whole subject of the card.
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: p.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

String _snapshotActionLabel(String action) {
  switch (action) {
    case 'reset_hard':
      return 'Hard reset';
    case 'force_push':
      return 'Force push';
    case 'rm_rf':
      return 'Recursive delete';
    case 'git_clean':
      return 'Clean untracked';
    default:
      return action;
  }
}

/// Floor width for the undo column. The affordance changes word as a snapshot
/// moves ("Undo" → "Undoing…" → "Undone"), and without a floor the subtitle
/// beside it re-wraps at a different point on every row of the section.
///
/// A floor, not a fixed width: an unrecognised state renders its own word here,
/// and clipping that would hide the only thing the row says about it.
const _undoColumnWidth = 68.0;

/// One reversible flagged action. The whole row is the tap target: the
/// snapshot buys prevention back as one tap, so nothing here opens a sheet or
/// a form.
class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({
    required this.snapshot,
    required this.meta,
    required this.pending,
    required this.onUndo,
    required this.p,
  });
  final HandlerSnapshot snapshot;
  final Widget meta;
  final bool pending;
  final VoidCallback onUndo;
  final AbColors p;

  /// Never an interactive-looking chip over an undo that would do nothing —
  /// a spent entry says so instead. A failed attempt keeps its tap because the
  /// bridge retries it; the reason it failed rides in the subtitle.
  Widget _affordance() {
    if (pending) return AbChip.label(label: 'Undoing…', color: p.textMuted);
    if (snapshot.undone) {
      return AbChip.label(label: 'Undone', color: p.textMuted);
    }
    if (snapshot.state == 'failed') {
      return AbChip.label(label: 'Retry undo', color: p.warning, onTap: onUndo);
    }
    if (snapshot.state == 'available') {
      return AbChip.label(label: 'Undo', color: p.accent, onTap: onUndo);
    }
    return AbChip.label(label: snapshot.state, color: p.textMuted);
  }

  @override
  Widget build(BuildContext context) {
    final live = snapshot.undoable && !pending;
    return AbListRow(
      leading: HandlerRail(
        icon: AbIcons.revert,
        color: live ? p.warning : p.textMuted,
      ),
      subtitleMaxLines: 2,
      crossAxisAlignment: CrossAxisAlignment.start,
      title: Text(
        _snapshotActionLabel(snapshot.action),
        style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            snapshot.trigger,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
          ),
          // Mono, not sans: every variant the bridge writes here names a SHA,
          // a ref or a path.
          Text(
            snapshot.summary,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
          ),
          if (snapshot.detail != null)
            Text(
              snapshot.detail!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.warning,
              ),
            ),
        ],
      ),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: _undoColumnWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _affordance(),
            const SizedBox(height: AbTokens.space2),
            meta,
          ],
        ),
      ),
      onTap: live ? onUndo : null,
    );
  }
}

/// The one report of a finished session, and the only Handler surface that
/// outlives the app restart between the 3am wrap-up and the 9am read — the
/// activity feed below is rebuilt from live messages and replays nothing.
///
/// Sans throughout: every line here is either the user's own goal, the judge's
/// prose about their backlog items, or a chrome label. Nothing is a path, a ref
/// or a command, which is what makes the undo row beside it mono and this one
/// not.
///
/// No `onTap`. The card is a report; the Undo section directly below owns the
/// only action a reader of it can take.
class _WrapUpCard extends StatelessWidget {
  const _WrapUpCard({
    required this.wrapUp,
    required this.meta,
    required this.openUndos,
    required this.p,
  });
  final HandlerWrapUp wrapUp;
  final Widget meta;

  /// Undo offers still standing for this session, counted live by the caller.
  final int openUndos;
  final AbColors p;

  /// Named after the outcome the backlog drawer and the feed already use for
  /// the same four states — a third spelling would read as a third concept.
  String _outcomeLabel(String status) => switch (status) {
    'done' => 'Done',
    'failed' => 'Failed',
    'blocked' => 'Blocked',
    _ => 'Skipped',
  };

  /// The failures and blocks are what the user has to act on, so they are the
  /// two the eye can find without reading — which is the whole reason the
  /// summary puts the non-`done` outcomes at its centre.
  Color _outcomeColor(String status) => switch (status) {
    'failed' => p.error,
    'blocked' => p.warning,
    _ => p.textMuted,
  };

  Widget _line(String text, Color color) => Text(
    text,
    style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: color),
  );

  @override
  Widget build(BuildContext context) {
    return AbListRow(
      // The feed's own `wrapped_up` glyph, so the durable card and the live row
      // read as one thing rather than two events.
      leading: HandlerRail(icon: AbIcons.check, color: p.textMuted),
      subtitleMaxLines: 2,
      crossAxisAlignment: CrossAxisAlignment.start,
      title: Text(
        'Wrapped up',
        style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wrapUp.goal.isNotEmpty) _line(wrapUp.goal, p.textMuted),
          for (final o in wrapUp.outcomes)
            _line(
              '${_outcomeLabel(o.status)}: ${o.items.join(', ')}'
              '${o.more > 0 ? ' +${o.more} more' : ''}',
              _outcomeColor(o.status),
            ),
          // Frozen on the record on purpose, unlike the undo count below: the
          // bridge drops the session's escalations on disarm, so nothing can
          // re-derive what it was stopped from doing.
          if (wrapUp.blockedTotal > 0)
            _line(
              '${wrapUp.blockedTotal} action(s) Handler could not take'
              '${wrapUp.blockedReasons.isEmpty ? '' : ': ${wrapUp.blockedReasons.join('; ')}'}',
              p.warning,
            ),
          if (openUndos > 0)
            _line('$openUndos flagged action(s) can still be undone', p.accent),
        ],
      ),
      trailing: meta,
    );
  }
}

String _itemDecisionLabel(String decision) {
  switch (decision) {
    case 'item_done':
      return 'Done';
    case 'item_blocked':
      return 'Blocked';
    case 'item_skipped':
      return 'Skipped';
    default:
      return 'Failed';
  }
}

/// What one activity row says, and in what tone.
(String, Color?) _activityTitle(
  HandlerActivityRecord r,
  AbColors p,
) => switch (r.decision) {
  'armed' => ('Armed', null),
  'goal_edited' => ('Goal edited', null),
  // The pass that decided nothing needed doing, and the most frequent row in
  // the feed by a wide margin. It keeps the judge's reason — that is the only
  // trace of what Handler saw while the user was away — but takes the muted
  // tone, because a feed scanned for what went wrong has to be skimmable past
  // the rows where nothing did.
  //
  // Named off the run state rather than in words of its own: the header pill
  // above this feed says "Watching" for the same state, and two spellings on
  // one screen read as two different sessions.
  'continue' => (
    '${handlerRunStateLabel(HandlerRunState.watching)}: ${r.reason}',
    p.textMuted,
  ),
  'handle' => ('Auto-answered: ${r.reason}', null),
  'escalate' => ('Escalated: ${r.reason}', null),
  // Skipped and failed read exactly like done, deliberately: a skip has to be
  // as visible as a completion, or "3 items skipped as moot" becomes the
  // summary an assistant that simply gave up would also write.
  'item_done' ||
  'item_blocked' ||
  'item_skipped' ||
  'item_failed' => ('${_itemDecisionLabel(r.decision)}: ${r.reason}', null),
  // Work the user asked for that will never be tracked. The status snapshot
  // that follows is identical to the one before, so this row is the only
  // place the instruction leaves a trace.
  'instruction_dropped' => ('Instruction dropped: ${r.reason}', null),
  // What an instruction permitted, beside what it asked for. "Clear out the
  // build dir" reads as a chore and also lifts the flag off that command for
  // the whole session, so the scope is stated rather than the act alone. The
  // bridge puts a lone lift in the reason and the totals there only once
  // there is more than one — so this row leads with what was allowed, the
  // same way round as the `floor_warning` row about the same command.
  'instruction_authorized' => ('Allowed for this session: ${r.reason}', null),
  // The list changed and the user did not touch it — they said something, and
  // Handler took a line off it or rewrote one. Named after the drawer they
  // recognise, with the item quoted in their own words: which of their lines
  // moved is the whole question, and it is the one thing the backlog itself can
  // no longer answer once the line is gone.
  'instruction_amended' => ('Backlog updated: ${r.reason}', null),
  // Advisory floor hit. The action went through — this row is the audit trail
  // prevention was traded for, so it is never conditional on what Handler
  // decided afterwards.
  'floor_warning' => ('Flagged: ${r.reason}', p.warning),
  // A completion the harness refused to bank. The status snapshot that
  // follows is identical to the one before it, so this row is the only trace
  // of a session that will now not wrap up on its own.
  'evidence_rejected' => ('Completion not verified: ${r.reason}', p.warning),
  'wrapped_up' => ('Wrapped up', null),
  'parked' => ('Paused: ${r.reason}', null),
  'resumed' => ('Resumed: ${r.reason}', null),
  _ => (r.reason, null),
};

/// The glyph in the reserved rail. It earns the width the rail costs on every
/// row: the feed is scanned for one kind of entry at a time far more often than
/// it is read top to bottom.
(String?, Color?) _activityGlyph(
  HandlerActivityRecord r,
  AbColors p,
) => switch (r.decision) {
  'armed' => (AbIcons.shield, p.accent),
  'goal_edited' => (AbIcons.list, p.textMuted),
  // Watched, nothing sent. The one glyph in the rail that stands for an
  // absence of action, so a column of them is what the eye skips over.
  'continue' => (AbIcons.eye, p.textMuted),
  'handle' => (AbIcons.send, p.accent),
  'escalate' => (AbIcons.bell, p.accent),
  'item_done' => (AbIcons.check, p.success),
  'item_blocked' => (AbIcons.warning, p.warning),
  'item_failed' => (AbIcons.error, p.error),
  'item_skipped' => (AbIcons.close, p.textMuted),
  'instruction_dropped' => (AbIcons.warning, p.textMuted),
  // A key, not a shield: `armed` already owns the accent shield, and a feed
  // scanned one kind of row at a time cannot be asked to tell two identical
  // glyphs apart by what a session had already done. Permission, not alarm.
  'instruction_authorized' => (AbIcons.password, p.accent),
  // The drawer's own Edit mark. A change the user made by hand and one
  // their sentence made for them are the same change to the same list, and
  // giving the second its own glyph would teach the pencil a second meaning.
  'instruction_amended' => (AbIcons.edit, p.accent),
  // The remit being tested. Shield in the warning tone, beside `armed`'s.
  'floor_warning' => (AbIcons.shield, p.warning),
  'evidence_rejected' => (AbIcons.warning, p.warning),
  'wrapped_up' => (AbIcons.check, p.textMuted),
  'parked' => (AbIcons.stop, p.warning),
  'resumed' => (AbIcons.start, p.textMuted),
  _ => (null, null),
};

Widget? _activitySubtitle(HandlerActivityRecord r, AbColors p) {
  final detail = r.detail;
  final mono = AbTokens.monoStyle(
    fontSize: AbTokens.fontXs,
    color: p.textMuted,
  );
  final sans = AbTokens.sansStyle(
    fontSize: AbTokens.fontXs,
    color: p.textMuted,
  );
  switch (r.decision) {
    case 'armed':
    case 'goal_edited':
    case 'resumed':
    // The judge's reason is the whole of a continue row and it is already the
    // title; the bridge sends no detail with one, and inventing a second line
    // for the feed's most repeated row would cost the rows around it.
    case 'continue':
      return null;
    case 'handle':
      return detail == null ? null : Text('→ $detail', style: mono);
    case 'floor_warning':
    // Commands, absolute paths and hosts — read as data, never as prose, and the
    // only part of the row a user can check against what they meant to allow.
    case 'instruction_authorized':
      return detail == null ? null : Text(detail, style: mono);
    case 'parked':
      // The bridge stamps the wake deadline into detail as an ISO instant.
      final wake = detail == null ? null : DateTime.tryParse(detail);
      return wake == null
          ? null
          : Text('resuming around ${dayAwareTime(wake)}', style: sans);
    case 'escalate':
    case 'item_done':
    case 'item_blocked':
    case 'item_skipped':
    case 'item_failed':
    case 'instruction_dropped':
    case 'evidence_rejected':
    // The items themselves, quoted — the user's own prose, and read as prose.
    case 'instruction_amended':
    // One line of the same summary the Wrap-up card renders in full. The card
    // is the durable copy; this row is the live one, and it is blank without
    // this arm because the title carries no reason for a wrap-up.
    case 'wrapped_up':
      return detail == null ? null : Text(detail, style: sans);
    default:
      // A kind this build has no arm for — a bridge ahead of the app. The row
      // still says something (its reason is the title), so the fallback prints
      // whatever came with it rather than the protocol word, which is a name the
      // user has never seen and cannot act on.
      return detail == null ? null : Text(detail, style: sans);
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.record,
    required this.meta,
    required this.p,
  });
  final HandlerActivityRecord record;
  final Widget meta;
  final AbColors p;

  @override
  Widget build(BuildContext context) {
    final (title, titleColor) = _activityTitle(record, p);
    final (icon, iconColor) = _activityGlyph(record, p);
    return AbListRow(
      leading: HandlerRail(icon: icon, color: iconColor),
      titleMaxLines: 2,
      subtitleMaxLines: 2,
      crossAxisAlignment: CrossAxisAlignment.start,
      title: Text(title, style: AbTokens.sansStyle(color: titleColor)),
      subtitle: _activitySubtitle(record, p),
      trailing: meta,
    );
  }
}
