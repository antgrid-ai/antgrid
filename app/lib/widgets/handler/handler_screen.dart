import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_state_chip.dart';
import '../../design/widgets/ab_toolbar.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../util/relative_time.dart';
import 'handler_backlog_drawer.dart';
import 'handler_decision_card.dart';
import 'handler_item_status.dart';
import 'handler_layout.dart';
import 'handler_reply_sheet.dart';

/// Day-aware, not a bare clock: this feed is written while the user is away and
/// read afterwards, so it routinely spans midnight.
String _fmtTime(int epochMs) =>
    dayAwareTime(DateTime.fromMillisecondsSinceEpoch(epochMs));

class HandlerScreen extends ConsumerWidget {
  const HandlerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(handlerStateProvider).value;
    return Column(
      children: [
        // Every other workspace tab opens with an AbToolbar (Files, Git,
        // Terminals, Preview). Handler opening straight into its list left it a
        // row out of step with all of them across the resizable divider.
        const AbToolbar.panel(title: 'Handler'),
        Expanded(child: _body(context, ref, state)),
      ],
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, HandlerState? state) {
    final p = context.antgrid;

    // Undo offers keep this screen alive after the last disarm: a wrapped-up
    // session is exactly when the force push it made at 3am gets read.
    if (state == null || (!state.anyArmed && state.snapshots.isEmpty)) {
      return const Padding(
        padding: EdgeInsets.all(AbTokens.space24),
        child: Center(
          child: AbEmptyState(
            icon: AbIcons.shield,
            title: 'Handler is off',
            subtitle:
                'Arm it with the shield at the end of the top bar. It then '
                'watches that session, answers what it can, and escalates the '
                'rest to you here.',
          ),
        ),
      );
    }

    final service = serviceWhenReady(ref, handlerServiceProvider);
    final container = ref.container;

    final entries = {
      for (final s in ref.watch(activeSessionsProvider)) s.id: s,
    };
    String nameOf(String terminalId) =>
        entries[terminalId]?.name ?? terminalId;
    // No catalog prediction here on purpose: every row on this screen is an
    // ARMED session, and the bridge's own per-session observability describes
    // its live mode and judge pick. The pre-arm guess belongs where nothing is
    // armed yet (the header's shield tooltip).

    // Show which session a row belongs to only when the screen is actually
    // mixing rows from more than one terminal — a single-session handler
    // repeating the same label on every row is noise.
    final distinctTerminals = <String>{
      ...state.sessions.keys,
      ...state.escalations.map((e) => e.terminalId),
      ...state.activity.map((a) => a.terminalId),
      ...state.snapshots.map((s) => s.terminalId),
    };
    final showSessionLabels = distinctTerminals.length > 1;

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

    Widget meta(String terminalId, int at) => _RowMeta(
      sessionName: showSessionLabels ? nameOf(terminalId) : null,
      at: at,
      p: p,
    );

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
                if (e.choices != null)
                  HandlerDecisionCard(
                    escalation: e,
                    trailing: meta(e.terminalId, e.at),
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
                    trailing: meta(e.terminalId, e.at),
                    onTap: () => answer(e),
                  ),
            ],
          ),
        ],
        if (state.sessions.isNotEmpty) ...[
          // Never conditional on the session count. Section headers here are
          // PINNED, so the band left standing over a headerless section is the
          // previous one — drop this and a lone session card scrolls up under
          // "NEEDS YOU", reading as an unanswered escalation.
          _section('Sessions', state.sessions.length, p.textMuted, p),
          SliverList.list(
            children: [
              for (final s in state.sessions.values)
                _SessionCard(
                  session: s,
                  sessionName: showSessionLabels ? nameOf(s.terminalId) : null,
                  // The sessionNames watch above already subscribes this build
                  // to session-list changes, so the resolver read stays
                  // reactive. The bare state.defaultTool is NOT a second
                  // resolution rule — it only fires while the service is still
                  // resolving (the resolver already includes it when the
                  // service is up).
                  judgeLabel:
                      s.judgeTool ??
                      service?.resolvedDefaultTool(s.terminalId) ??
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
                  onOpenBacklog: () => unawaited(
                    showHandlerBacklogDrawer(context, s.terminalId),
                  ),
                ),
            ],
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
                meta: meta(s.terminalId, s.at),
                pending: state.pendingUndo.contains(s.snapshotId),
                onUndo: () =>
                    focusedServiceOrNull(container, (x) => x.handlerService)?.undo(s),
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
              return _ActivityRow(
                record: a,
                meta: meta(a.terminalId, a.at),
                p: p,
              );
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

/// Right-aligned session/time metadata shown on escalation and activity rows.
class _RowMeta extends StatelessWidget {
  const _RowMeta({
    required this.sessionName,
    required this.at,
    required this.p,
  });
  final String? sessionName;
  final int at;
  final AbColors p;

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
        if (sessionName != null) Text(sessionName!, style: style),
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
/// Armed chip. Everything else that could grow (the judge name, the session
/// name, the notify-only marker) either shrinks or sits on a line below, so a
/// narrow context panel or a scaled text size cannot overflow the row.
class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.sessionName,
    required this.judgeLabel,
    required this.onDisarm,
    required this.onOpenBacklog,
  });
  final HandlerSessionState session;
  final String? sessionName;

  /// Resolved judge CLI, rendered read-only on the status line (override, else
  /// the session's default). This never mutates it.
  final String judgeLabel;
  final VoidCallback onDisarm;
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
                // Its own full-width line, not a slot on the status row: names
                // only render when several sessions are on screen, which is
                // exactly when they share a prefix and a truncated one
                // identifies nothing.
                if (sessionName != null || session.notifyOnly)
                  Row(
                    children: [
                      if (sessionName != null)
                        Flexible(
                          child: Text(
                            sessionName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mutedMono,
                          ),
                        ),
                      // A notify-only session never acts on the user's behalf,
                      // which is the single biggest thing this card can be
                      // wrong about by staying silent.
                      if (session.notifyOnly) ...[
                        if (sessionName != null)
                          const SizedBox(width: AbTokens.space6),
                        AbChip.system(label: 'NOTIFY ONLY', color: p.warning),
                      ],
                    ],
                  ),
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
            _ProgressRule(
              done: session.backlogDone,
              total: session.backlogTotal,
              p: p,
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

/// Completion as a rule rather than only as a sentence — "3 of 7" has to be
/// read, and this card is scanned past far more often than it is read.
///
/// The track is [AbColors.bgElevated] rather than a border tint, because at 0%
/// done — every session's first minutes — the track is the whole widget, and a
/// hairline in a border colour is indistinguishable from the row dividers
/// around it.
class _ProgressRule extends StatelessWidget {
  const _ProgressRule({
    required this.done,
    required this.total,
    required this.p,
  });
  final int done;
  final int total;
  final AbColors p;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: p.bgElevated),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: total == 0 ? 0 : (done / total).clamp(0.0, 1.0),
            child: ColoredBox(color: p.accent),
          ),
        ],
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

/// One reversible flagged action. The whole row is the tap target: §5.2 buys
/// prevention back as one tap, so nothing here opens a sheet or a form.
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
(String, Color?) _activityTitle(HandlerActivityRecord r, AbColors p) =>
    switch (r.decision) {
      'armed' => ('Armed', null),
      'goal_edited' => ('Goal edited', null),
      'handle' => ('Auto-answered: ${r.reason}', null),
      'escalate' => ('Escalated: ${r.reason}', null),
      // Skipped and failed read exactly like done, deliberately: §4.3 requires
      // a skip to be as visible as a completion, or "3 items skipped as moot"
      // becomes the summary an assistant that simply gave up would also write.
      'item_done' ||
      'item_blocked' ||
      'item_skipped' ||
      'item_failed' => ('${_itemDecisionLabel(r.decision)}: ${r.reason}', null),
      // Work the user asked for that will never be tracked. The status snapshot
      // that follows is identical to the one before, so this row is the only
      // place the instruction leaves a trace.
      'instruction_dropped' => ('Instruction dropped: ${r.reason}', null),
      // Advisory floor hit (spec §5.1). The action went through — this row is
      // the audit trail prevention was traded for, so it is never conditional
      // on what Handler decided afterwards.
      'floor_warning' => ('Flagged: ${r.reason}', p.warning),
      'wrapped_up' => ('Wrapped up', null),
      'parked' => ('Paused: ${r.reason}', null),
      'resumed' => ('Resumed: ${r.reason}', null),
      _ => (r.reason, null),
    };

/// The glyph in the reserved rail. It earns the width the rail costs on every
/// row: the feed is scanned for one kind of entry at a time far more often than
/// it is read top to bottom.
(String?, Color?) _activityGlyph(HandlerActivityRecord r, AbColors p) =>
    switch (r.decision) {
      'armed' => (AbIcons.shield, p.accent),
      'goal_edited' => (AbIcons.list, p.textMuted),
      'handle' => (AbIcons.send, p.accent),
      'escalate' => (AbIcons.bell, p.accent),
      'item_done' => (AbIcons.check, p.success),
      'item_blocked' => (AbIcons.warning, p.warning),
      'item_failed' => (AbIcons.error, p.error),
      'item_skipped' => (AbIcons.close, p.textMuted),
      'instruction_dropped' => (AbIcons.warning, p.textMuted),
      'floor_warning' => (AbIcons.shield, p.warning),
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
    case 'wrapped_up':
    case 'resumed':
      return null;
    case 'handle':
      return detail == null ? null : Text('→ $detail', style: mono);
    case 'floor_warning':
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
      return detail == null ? null : Text(detail, style: sans);
    default:
      return Text(r.decision, style: mono);
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
