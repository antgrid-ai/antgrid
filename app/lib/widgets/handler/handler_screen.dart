import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_carbon.dart';
import '../../models/handler_state.dart';
import '../../models/workspace_view.dart';
import '../../providers/providers.dart';
import '../../providers/visible_surface.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import '../carbon_confirm.dart';
import '../carbon_empty_state.dart';
import 'handler_ask_footer.dart';
import 'handler_backlog_drawer.dart';
import 'handler_escalation_answer.dart';
import 'handler_escalation_row.dart';
import 'handler_item_status.dart';
import 'handler_layout.dart';
import 'handler_session_settings.dart';

class HandlerScreen extends ConsumerWidget {
  const HandlerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _maybeFetchHistory(ref);
    // The scope is the screen's own root and never moves: the body below it is
    // where every modal and menu is presented from, so they all resolve the
    // Carbon theme through it.
    return AbCarbonScope(
      child: _HandlerBody(state: ref.watch(focusedSessionHandlerStateProvider)),
    );
  }

  /// Ask for the activity log the first time this tab is actually looked at.
  ///
  /// `workspace_panel.dart` mounts every tab through an IndexedStack, so this
  /// widget is built on every project open whether or not anyone selects it —
  /// which is why the trigger is the visible view rather than the mount. An
  /// unconditional fetch here would put a request on the wire for every project
  /// in every app, the eager-hydration shape that stalled the relay window once
  /// already.
  ///
  /// Watched rather than read: the flag has to be recomputed when the tab comes
  /// on screen, exactly as `git_panel.dart` does it. [HandlerService.
  /// activateHistory] is idempotent, so repeated builds cost nothing, and the
  /// tab going back off screen deliberately does NOT deactivate — a project
  /// whose history the user has looked at once keeps it fresh across reconnects
  /// for one bounded page, which is worth more than the request it saves.
  void _maybeFetchHistory(WidgetRef ref) {
    if (ref.watch(visibleWorkspaceViewProvider) != WorkspaceView.handler) {
      return;
    }
    final service = serviceWhenReady(ref, handlerServiceProvider);
    if (service == null) return;
    // Out of the build phase: activateHistory emits state the moment a page
    // lands, and a provider written to during build throws.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => service.activateHistory(),
    );
  }
}

class _HandlerBody extends ConsumerWidget {
  const _HandlerBody({required this.state});

  final HandlerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = CarbonTheme.of(context);

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
      return ColoredBox(
        color: theme.colors.background,
        child: const CarbonEmptyState(
          icon: CarbonIcons.security,
          heading: 'Handler is off for this session',
          body:
              'Arm it with the shield at the end of the top bar. It then '
              'watches this session, answers what it can, and escalates the '
              'rest to you here. This tab answers for one session — '
              'another that needs you is counted on its own agent header.',
        ),
      );
    }

    final service = serviceWhenReady(ref, handlerServiceProvider);
    final container = ref.container;

    // No catalog prediction here on purpose: every row on this screen is an
    // ARMED session, and the bridge's own per-session observability describes
    // its live mode and judge pick. The pre-arm guess belongs where nothing is
    // armed yet (the header's shield tooltip).

    // Confirmed for one action out of four. Undoing a hard reset, a recursive
    // delete or a clean touches this machine only; undoing a force push writes
    // to a shared remote, and the row it is offered on is a scrolling list row
    // whose whole body is the tap target, because the snapshot buys prevention
    // back as one tap.
    // The dialog is the only thing standing between a thumb landing where the
    // scroll stopped and a ref overwritten for everyone on it.
    //
    // Re-resolved after the dialog for the same reason
    // [answerHandlerEscalation] re-resolves after its sheet: the focused
    // project's session can be rebuilt while the dialog is open, and the
    // build-time instance is disposed by then.
    Future<void> undo(HandlerSnapshot s) async {
      if (s.action == 'force_push') {
        final ok = await showCarbonConfirm(
          context,
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
          danger: true,
        );
        if (!ok) return;
      }
      focusedServiceOrNull(container, (x) => x.handlerService)?.undo(s);
    }

    final escalations = state.escalations;
    final sessions = state.sessions.values.toList();
    final activityNote = theme.typography.body.copyWith(
      color: theme.colors.textSecondary,
    );
    return ColoredBox(
      color: theme.colors.background,
      child: CustomScrollView(
        slivers: [
          // Actionable first. The old order opened with the session headers, so
          // two armed sessions carrying a backlog each pushed the one section
          // the user came here to act on several hundred pixels down the list.
          if (escalations.isNotEmpty)
            _section(
              'Needs you',
              count: escalations.length,
              countColor: handlerToneTagColor(HandlerTone.accent),
              itemCount: escalations.length,
              itemBuilder: (_, i) {
                final e = escalations[i];
                return HandlerEscalationRow(
                  escalation: e,
                  // The OWNING session's backlog: the ask footer's claim is
                  // only checkable against the items that session is actually
                  // running, and this screen is the one surface holding them.
                  backlog: state.sessions[e.terminalId]?.backlog ?? const [],
                  onReply: service == null
                      ? null
                      : () => detached(
                          'HandlerScreen',
                          'answer escalation',
                          () => answerHandlerEscalation(context, container, e),
                        ),
                  // Re-resolved through the container for the same reason
                  // [answerHandlerEscalation] re-resolves after its sheet: the
                  // build-time instance can be disposed by a tap landing, and a
                  // disposed service answers `false` — which a card reads as a
                  // refusal and correctly declines to latch on, so today this
                  // only ever cost a tap. Re-resolving makes that tap land.
                  onDismiss: service == null
                      ? null
                      : () => focusedServiceOrNull(
                          container,
                          (s) => s.handlerService,
                        )?.dismiss(e),
                  onChoice: service == null
                      ? null
                      : (choiceId) =>
                            focusedServiceOrNull(
                              container,
                              (s) => s.handlerService,
                            )?.answerWithChoice(e, choiceId) ??
                            false,
                  onAskOption: service == null
                      ? null
                      : (choiceId) =>
                            focusedServiceOrNull(
                              container,
                              (s) => s.handlerService,
                            )?.answerAsk(e, choiceId) ??
                            false,
                );
              },
            ),
          // Section headers here are PINNED, so the band left standing over a
          // headerless section is the previous one — drop this and the session
          // card scrolls up under "Needs you", reading as an unanswered
          // escalation.
          if (sessions.isNotEmpty)
            _section(
              'Session',
              itemCount: sessions.length,
              itemBuilder: (_, i) {
                final s = sessions[i];
                return _SessionCard(
                  session: s,
                  // Through the shared resolver, which carries the
                  // session-list subscription its own read needs — resolving
                  // off the service directly here would pin whatever the list
                  // said on first build. The bare state.defaultTool is NOT a
                  // second resolution rule: it only fires while the service is
                  // still resolving (the resolver already includes it when the
                  // service is up).
                  judgeLabel:
                      handlerEffectiveJudge(ref, s.terminalId, s.judgeTool) ??
                      state.defaultTool ??
                      'default',
                  // Resolved at tap time, not captured here: this fires from a
                  // menu entry that runs after its popup closes, and the
                  // focused project's session can be rebuilt while that menu is
                  // open (host restart, eviction, connection retry). The
                  // build-time instance would be disposed by then and swallow
                  // the disarm.
                  onDisarm: () => focusedServiceOrNull(
                    container,
                    (x) => x.handlerService,
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
                );
              },
            ),
          // Below Sessions because a report is not an action, and directly
          // above Undo because its last line points at that section.
          if (state.wrapUps.isNotEmpty)
            _section(
              'Wrap-up',
              count: state.wrapUps.length,
              itemCount: state.wrapUps.length,
              itemBuilder: (_, i) {
                final w = state.wrapUps[state.wrapUps.length - 1 - i];
                return _WrapUpCard(
                  wrapUp: w,
                  meta: HandlerRowMeta(at: w.at),
                  // Derived, never read off the record: an undo taken after the
                  // wrap-up spends its entry and a re-arm retires the offers
                  // outright, so a count frozen at compose time is a lie on the
                  // one surface built to be read hours later. This is the same
                  // list the Undo section below renders, so the two cannot
                  // disagree.
                  openUndos: state.snapshots
                      .where((s) => s.terminalId == w.terminalId && !s.undone)
                      .length,
                );
              },
            ),
          // Lazy for the same reason the activity feed below is: the store
          // keeps up to MAX_STORED offers and every flagged inject re-sends its
          // row.
          if (state.snapshots.isNotEmpty)
            _section(
              'Undo',
              count: state.snapshots.length,
              countColor: handlerToneTagColor(HandlerTone.warning),
              itemCount: state.snapshots.length,
              itemBuilder: (_, i) {
                final s = state.snapshots[state.snapshots.length - 1 - i];
                return _SnapshotRow(
                  snapshot: s,
                  meta: HandlerRowMeta(at: s.at),
                  pending: state.pendingUndo.contains(s.snapshotId),
                  onUndo: () =>
                      detached('HandlerScreen', 'undo snapshot', () => undo(s)),
                );
              },
            ),
          // Built lazily, unlike the ListView this replaced: the feed is capped
          // at 200 rows and a new one arrives on every judge decision, so
          // constructing all of them per message was a cost paid continuously.
          _section(
            'Activity',
            itemCount: state.activity.length,
            // An unanswered history request and a project that has never armed
            // Handler both render as no rows. Said plainly, so a fetch that
            // stalled is not read as the settled fact that nothing happened.
            status: state.activityHistoryError != null
                ? CarbonContainedListStatus.error
                : CarbonContainedListStatus.content,
            errorContent: state.activityHistoryError == null
                ? null
                : _NoteLine(state.activityHistoryError!, HandlerTone.warning),
            emptyContent: Text('No activity yet.', style: activityNote),
            itemBuilder: (_, i) {
              final a = state.activity[i];
              return _ActivityRow(record: a, meta: HandlerRowMeta(at: a.at));
            },
          ),
          // Last, under the oldest row it has, because that is where the feed
          // stops. Rendering it is the point: a page of the newest 50 out of
          // 300 with nothing saying so presents a truncated history as a whole
          // one.
          if (state.activityTruncated && state.activity.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: handlerGutter,
                  vertical: CarbonSpacing.spacing05,
                ),
                child: Text('Older activity is not shown.', style: activityNote),
              ),
            ),
        ],
      ),
    );
  }

  /// Pinned, because the activity feed runs to 200 rows and a boundary that
  /// scrolls away takes with it the only thing saying which section the row
  /// under the user's thumb belongs to.
  ///
  /// Disclosed, so the rows stay clear on the page and only the actionable
  /// cards are filled.
  Widget _section(
    String label, {
    int? count,
    CarbonTagColor countColor = CarbonTagColor.gray,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    CarbonContainedListStatus status = CarbonContainedListStatus.content,
    Widget? errorContent,
    Widget? emptyContent,
  }) => CarbonContainedListSliver(
    label: label,
    pinned: true,
    variant: CarbonContainedListVariant.disclosed,
    action: count == null
        ? null
        : Padding(
            padding: const EdgeInsetsDirectional.only(
              end: CarbonSpacing.spacing05,
            ),
            child: CarbonTag(
              label: '$count',
              size: CarbonTagSize.small,
              color: countColor,
            ),
          ),
    itemCount: itemCount,
    itemBuilder: itemBuilder,
    status: status,
    errorContent: errorContent,
    emptyContent: emptyContent,
  );
}

/// A line of secondary prose that may carry a tone.
///
/// A warning is a glyph beside secondary text rather than coloured text: the
/// warning ink that is legible as a glyph is not legible as 12px type, and the
/// glyph is what survives for a reader who cannot tell the colours apart.
class _NoteLine extends StatelessWidget {
  const _NoteLine(this.text, this.tone, {this.code = false});

  final String text;
  final HandlerTone? tone;

  /// Verbatim wire data, so it is set in the code face.
  final bool code;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final base = code ? theme.typography.code : theme.typography.helper;
    final t = tone;
    final ink =
        t == null ||
            t == HandlerTone.quiet ||
            t == HandlerTone.secondary ||
            t == HandlerTone.warning
        ? colors.textSecondary
        : handlerToneColor(colors, t);
    final label = Text(text, style: base.copyWith(color: ink));
    if (tone != HandlerTone.warning) return label;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: CarbonSpacing.spacing01),
          child: CarbonIcon(
            CarbonIcons.warningFilled,
            size: handlerRailWidth,
            color: colors.supportWarning,
          ),
        ),
        const SizedBox(width: CarbonSpacing.spacing03),
        Expanded(child: label),
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
  final reason = handlerParkReason(session);
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
/// Only the status line's own ends are fixed — the run-state word and the
/// Armed tag with its menu. Everything else that could grow (the judge name)
/// either shrinks or sits on a line below, so a narrow context panel or a
/// scaled text size cannot overflow the row.
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

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final hiddenItems = session.backlogTotal - _maxItemRows;
    final visibleItems = hiddenItems > 0
        ? session.backlog.sublist(0, _maxItemRows)
        : session.backlog;
    // The same split the header pill takes, from the same shared vocabulary:
    // this card and that pill are on screen together on desktop, and one of
    // them saying the session stopped while the other says it asked reads as
    // two different sessions.
    final asksOnly = session.asksOnly;
    final tone = handlerRunStateTone(session.runState, asksOnly: asksOnly);
    final parkNote = handlerParkNote(session);
    final availabilityNote =
        session.observability != HandlerObservability.unsupported
        ? session.availability?.note
        : null;
    Widget notice(String text) => Padding(
      padding: const EdgeInsets.only(top: CarbonSpacing.spacing02),
      child: CarbonNotification(
        kind: CarbonNotificationKind.warning,
        subtitle: text,
        announce: false,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: handlerGutter,
            vertical: CarbonSpacing.spacing03,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Empty on purpose: this card carries no conditional glyph,
                  // but it shares a list with rows that do, and the reserved
                  // slot is what puts every title on one column.
                  const HandlerRail(),
                  const SizedBox(width: CarbonSpacing.spacing04),
                  Expanded(
                    child: Row(
                      children: [
                        // Flexible, weighted above the judge name: the word is
                        // what the card is for, but at the narrowest panel it
                        // is the only thing that can still give way.
                        Flexible(
                          flex: 3,
                          child: Text(
                            handlerRunStateLabel(
                              session.runState,
                              asksOnly: asksOnly,
                            ),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: theme.typography.control.copyWith(
                              fontWeight: FontWeight.w600,
                              color: handlerToneColor(colors, tone),
                            ),
                          ),
                        ),
                        const SizedBox(width: CarbonSpacing.spacing03),
                        // The only child of this row allowed to grow, so it is
                        // also the only one that has to give way. The judge CLI
                        // is a bare tool name with nothing beside it to say so
                        // — the tooltip is what names the column.
                        Flexible(
                          child: CarbonTooltip(
                            message: 'Judge',
                            child: Text(
                              judgeLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.typography.code.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        // Beside the judge name because that is what it
                        // qualifies: the named judge cannot run headless, so
                        // nothing it sees gets answered without the user.
                        if (session.observability ==
                            HandlerObservability.escalateOnly) ...[
                          const SizedBox(width: CarbonSpacing.spacing03),
                          const CarbonTooltip(
                            message: escalateOnlyNotice,
                            child: CarbonTag(
                              label: 'Escalate only',
                              size: CarbonTagSize.small,
                              color: CarbonTagColor.warmGray,
                            ),
                          ),
                        ],
                        // The answer has been given and has not reached the
                        // agent yet. It is the only surface that ever exposes a
                        // relay that is still waiting or has failed — the ask
                        // row itself is retired the moment the answer goes out,
                        // so without this the user has nothing at all between
                        // their tap and Handler's next pass.
                        if (session.askAnswerPending) ...[
                          const SizedBox(width: CarbonSpacing.spacing03),
                          const CarbonTooltip(
                            message: handlerAskLatencyNote,
                            child: CarbonTag(
                              label: 'Answer queued',
                              size: CarbonTagSize.small,
                              color: CarbonTagColor.coolGray,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: CarbonSpacing.spacing03),
                  // A state, not a control: disarm sits behind the menu beside
                  // it, because a tap on a tag that silently turned Handler off
                  // would be a control whose label contradicts its effect, and
                  // this one is a mis-tap away from a scrolling list.
                  const CarbonTooltip(
                    message: 'Handler is armed on this session',
                    child: CarbonTag(
                      label: 'Armed',
                      size: CarbonTagSize.small,
                      color: CarbonTagColor.green,
                    ),
                  ),
                  CarbonOverflowMenu(
                    semanticLabel: 'Handler options',
                    size: CarbonButtonSize.small,
                    entries: [
                      CarbonMenuItem(
                        label: 'Handler settings',
                        icon: const CarbonIcon(CarbonIcons.settings),
                        onPressed: onOpenSettings,
                      ),
                      CarbonMenuItem(
                        label: 'Disarm Handler',
                        icon: const CarbonIcon(CarbonIcons.security),
                        kind: CarbonMenuItemKind.danger,
                        onPressed: onDisarm,
                      ),
                    ],
                  ),
                ],
              ),
              // Everything under the status line hangs off it rather than off
              // the card edge, so the card reads as one session.
              Padding(
                padding: const EdgeInsets.only(left: handlerRailInset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (parkNote != null) notice(parkNote),
                    // Only ever rendered from the session's OWN report: a
                    // bridge that sends no observability leaves this silent
                    // rather than guessing from the agent it happens to run.
                    if (session.observability ==
                        HandlerObservability.unsupported)
                      notice(
                        'Not watched — this agent reports nothing the '
                        'Handler can act on.',
                      ),
                    if (availabilityNote != null) notice(availabilityNote),
                    const SizedBox(height: CarbonSpacing.spacing02),
                    Text(
                      // A 1-tap arm legitimately has no goal until extraction
                      // resolves behind the handoff, so this is a normal state,
                      // and reads as one: an absence must not be the loudest
                      // text on the panel.
                      session.goal.isEmpty ? 'No goal yet' : session.goal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.body.copyWith(
                        color: session.goal.isEmpty
                            ? colors.textSecondary
                            : colors.textPrimary,
                        fontWeight: session.goal.isEmpty
                            ? null
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (session.backlogTotal > 0)
          _BacklogSummary(
            session: session,
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            onTap: onOpenBacklog,
          )
        else
          SizedBox(
            height: CarbonBorders.hairline,
            child: ColoredBox(
              color: theme.borderSubtle(CarbonLayer.of(context)),
            ),
          ),
      ],
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
  });
  final HandlerSessionState session;
  final List<HandlerInstructionItem> visibleItems;
  final int hiddenItems;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final helper = theme.typography.helper.copyWith(
      color: colors.textSecondary,
    );
    final progress = handlerProgressLabel(session);
    return CarbonContainedListRow(
      title: [
        progress,
        if (hiddenItems > 0) '$hiddenItems more',
        for (final item in visibleItems) item.text,
      ].join('. '),
      // Same slot as the status line's glyph, so the progress hangs off the
      // same column as the goal above it.
      leading: const HandlerRail(),
      onPressed: onTap,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          CarbonProgressBar(
            value: session.backlogTotal == 0
                ? 0
                : session.backlogDone / session.backlogTotal,
            size: CarbonProgressBarSize.small,
            label: 'Backlog progress',
            hideLabel: true,
          ),
          const SizedBox(height: CarbonSpacing.spacing03),
          Row(
            children: [
              Expanded(child: Text(progress, style: helper)),
              // The overflow count rides next to the affordance that reveals
              // it, not buried at the end of the progress sentence.
              if (hiddenItems > 0) ...[
                Text('$hiddenItems more', style: helper),
                const SizedBox(width: CarbonSpacing.spacing02),
              ],
              CarbonIcon(
                CarbonIcons.chevronRight,
                size: handlerRailWidth,
                color: colors.iconSecondary,
              ),
            ],
          ),
          for (final item in visibleItems) ...[
            const SizedBox(height: CarbonSpacing.spacing02),
            _BacklogItemRow(item: item),
          ],
        ],
      ),
    );
  }
}

/// One backlog item: its status, then the user's own words for it.
class _BacklogItemRow extends StatelessWidget {
  const _BacklogItemRow({required this.item});
  final HandlerInstructionItem item;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HandlerItemStatusLabel(status: item.status),
        const SizedBox(width: CarbonSpacing.spacing03),
        Expanded(
          child: Text(
            item.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            // The item is the content of this block, not a caption on it: what
            // the session was asked to do is the whole subject of the card.
            style: theme.typography.helper.copyWith(
              color: theme.colors.textSecondary,
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
const _undoColumnWidth = CarbonSpacing.spacing10;

/// One reversible flagged action. The whole row is the tap target: the
/// snapshot buys prevention back as one tap, so nothing here opens a sheet or
/// a form.
class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({
    required this.snapshot,
    required this.meta,
    required this.pending,
    required this.onUndo,
  });
  final HandlerSnapshot snapshot;
  final Widget meta;
  final bool pending;
  final VoidCallback onUndo;

  /// Never an interactive-looking tag over an undo that would do nothing — a
  /// spent entry says so instead. A failed attempt keeps its tap because the
  /// bridge retries it; the reason it failed rides in the detail line.
  ///
  /// The tags carry no press handler of their own: the row is the target, and
  /// an interactive tag would take the tap the row is meant to receive.
  Widget _affordance() {
    final (label, color) = pending
        ? ('Undoing…', CarbonTagColor.gray)
        : snapshot.undone
        ? ('Undone', CarbonTagColor.gray)
        : snapshot.state == 'failed'
        ? ('Retry undo', CarbonTagColor.warmGray)
        : snapshot.state == 'available'
        ? ('Undo', CarbonTagColor.blue)
        : (snapshot.state, CarbonTagColor.gray);
    return CarbonTag(label: label, size: CarbonTagSize.small, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final live = snapshot.undoable && !pending;
    final title = _snapshotActionLabel(snapshot.action);
    final state = pending
        ? 'Undoing'
        : snapshot.undone
        ? 'Undone'
        : snapshot.state == 'failed'
        ? 'Retry undo'
        : snapshot.state == 'available'
        ? 'Undo'
        : snapshot.state;
    return CarbonContainedListRow(
      title: [
        title,
        state,
        snapshot.trigger,
        snapshot.summary,
        ?snapshot.detail,
      ].join('. '),
      leading: HandlerRail(
        icon: CarbonIcons.undo,
        color: live ? colors.supportWarning : colors.iconSecondary,
      ),
      onPressed: live ? onUndo : null,
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.typography.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _NoteLine(snapshot.trigger, null, code: true),
                // Code face, not sans: every variant the bridge writes here
                // names a SHA, a ref or a path.
                _NoteLine(snapshot.summary, null, code: true),
                if (snapshot.detail != null)
                  _NoteLine(snapshot.detail!, HandlerTone.warning),
              ],
            ),
          ),
          const SizedBox(width: CarbonSpacing.spacing03),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _undoColumnWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _affordance(),
                const SizedBox(height: CarbonSpacing.spacing01),
                meta,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The one report of a finished session, and the only Handler surface that
/// outlives the app restart between the 3am wrap-up and the 9am read — the
/// activity feed below is rebuilt from live messages and replays nothing.
///
/// Sans throughout: every line here is either the user's own goal, the judge's
/// prose about their backlog items, or a chrome label. Nothing is a path, a ref
/// or a command, which is what makes the undo row beside it code-faced and this
/// one not.
///
/// No press handler. The card is a report; the Undo section directly below owns
/// the only action a reader of it can take.
class _WrapUpCard extends StatelessWidget {
  const _WrapUpCard({
    required this.wrapUp,
    required this.meta,
    required this.openUndos,
  });
  final HandlerWrapUp wrapUp;
  final Widget meta;

  /// Undo offers still standing for this session, counted live by the caller.
  final int openUndos;

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
  HandlerTone _outcomeTone(String status) => switch (status) {
    'failed' => HandlerTone.error,
    'blocked' => HandlerTone.warning,
    _ => HandlerTone.quiet,
  };

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return CarbonContainedListRow(
      title: [
        'Wrapped up',
        if (wrapUp.goal.isNotEmpty) wrapUp.goal,
        for (final o in wrapUp.outcomes)
          '${_outcomeLabel(o.status)}: ${o.items.join(', ')}'
              '${o.more > 0 ? ' +${o.more} more' : ''}',
        if (wrapUp.blockedTotal > 0)
          '${wrapUp.blockedTotal} action(s) Handler could not take'
              '${wrapUp.blockedReasons.isEmpty ? '' : ': ${wrapUp.blockedReasons.join('; ')}'}',
        if (openUndos > 0) '$openUndos flagged action(s) can still be undone',
      ].join('. '),
      // The feed's own `wrapped_up` glyph, so the durable card and the live row
      // read as one thing rather than two events.
      leading: HandlerRail(
        icon: CarbonIcons.checkmark,
        color: theme.colors.iconSecondary,
      ),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Wrapped up',
                  style: theme.typography.body.copyWith(
                    color: theme.colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (wrapUp.goal.isNotEmpty) _NoteLine(wrapUp.goal, null),
                for (final o in wrapUp.outcomes)
                  _NoteLine(
                    '${_outcomeLabel(o.status)}: ${o.items.join(', ')}'
                    '${o.more > 0 ? ' +${o.more} more' : ''}',
                    _outcomeTone(o.status),
                  ),
                // Frozen on the record on purpose, unlike the undo count below:
                // the bridge drops the session's escalations on disarm, so
                // nothing can re-derive what it was stopped from doing.
                if (wrapUp.blockedTotal > 0)
                  _NoteLine(
                    '${wrapUp.blockedTotal} action(s) Handler could not take'
                    '${wrapUp.blockedReasons.isEmpty ? '' : ': ${wrapUp.blockedReasons.join('; ')}'}',
                    HandlerTone.warning,
                  ),
                if (openUndos > 0)
                  _NoteLine(
                    '$openUndos flagged action(s) can still be undone',
                    HandlerTone.accent,
                  ),
              ],
            ),
          ),
          const SizedBox(width: CarbonSpacing.spacing03),
          meta,
        ],
      ),
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

/// What one activity row says, and in what tone. A null tone is ordinary prose.
(String, HandlerTone?) _activityTitle(HandlerActivityRecord r) =>
    switch (r.decision) {
      'armed' => ('Armed', null),
      // Nothing was edited — a re-configure stacked a sentence that wasn't
      // already in the list, and entry #1 (the header's goal) didn't move.
      // Over a non-empty backlog this row is the only place that sentence ever
      // surfaces, so the title has to carry it rather than a fixed label.
      'goal_edited' => ('Also asked: ${r.reason}', null),
      // The pass that decided nothing needed doing, and the most frequent row
      // in the feed by a wide margin. It keeps the judge's reason — that is the
      // only trace of what Handler saw while the user was away — but takes the
      // quiet tone, because a feed scanned for what went wrong has to be
      // skimmable past the rows where nothing did.
      //
      // Named off the run state rather than in words of its own: the header
      // pill above this feed says "Watching" for the same state, and two
      // spellings on one screen read as two different sessions.
      'continue' => (
        '${handlerRunStateLabel(HandlerRunState.watching)}: ${r.reason}',
        HandlerTone.quiet,
      ),
      'handle' => ('Auto-answered: ${r.reason}', null),
      'escalate' => ('Escalated: ${r.reason}', null),
      // A question the agent kept working under, and what became of it. Never
      // "Escalated": that word is the one the feature exists to avoid, and a
      // bell beside it would file the question with the stops.
      'asked' => ('Asked you: ${r.reason}', null),
      'ask_rejected' => ('Question not raised: ${r.reason}', HandlerTone.warning),
      // The bridge writes these as whole sentences ("You answered Handler's
      // question") because the row is the user's own act, not a verdict a label
      // could prefix.
      'answered' => (r.reason, null),
      // Skipped and failed read exactly like done, deliberately: a skip has to
      // be as visible as a completion, or "3 items skipped as moot" becomes the
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
      // build dir" reads as a chore and also lifts the flag off that command
      // for the whole session, so the scope is stated rather than the act
      // alone. The bridge puts a lone lift in the reason and the totals there
      // only once there is more than one — so this row leads with what was
      // allowed, the same way round as the `floor_warning` row about the same
      // command.
      'instruction_authorized' => ('Allowed for this session: ${r.reason}', null),
      // The list changed and the user did not touch it — they said something,
      // and Handler took a line off it or rewrote one. Named after the drawer
      // they recognise, with the item quoted in their own words: which of their
      // lines moved is the whole question, and it is the one thing the backlog
      // itself can no longer answer once the line is gone.
      'instruction_amended' => ('Backlog updated: ${r.reason}', null),
      // Advisory floor hit. The action went through — this row is the audit
      // trail prevention was traded for, so it is never conditional on what
      // Handler decided afterwards.
      'floor_warning' => ('Flagged: ${r.reason}', HandlerTone.warning),
      // A completion the harness refused to bank. The status snapshot that
      // follows is identical to the one before it, so this row is the only
      // trace of a session that will now not wrap up on its own.
      'evidence_rejected' => (
        'Completion not verified: ${r.reason}',
        HandlerTone.warning,
      ),
      'wrapped_up' => ('Wrapped up', null),
      'parked' => ('Paused: ${r.reason}', null),
      'resumed' => ('Resumed: ${r.reason}', null),
      _ => (r.reason, null),
    };

/// The glyph in the reserved rail. It earns the width the rail costs on every
/// row: the feed is scanned for one kind of entry at a time far more often than
/// it is read top to bottom.
(CarbonIcons?, HandlerTone?) _activityGlyph(HandlerActivityRecord r) =>
    switch (r.decision) {
      'armed' => (CarbonIcons.security, HandlerTone.accent),
      'goal_edited' => (CarbonIcons.listBulleted, HandlerTone.quiet),
      // Watched, nothing sent. The one glyph in the rail that stands for an
      // absence of action, so a column of them is what the eye skips over.
      'continue' => (CarbonIcons.view, HandlerTone.quiet),
      'handle' => (CarbonIcons.send, HandlerTone.accent),
      'escalate' => (CarbonIcons.notification, HandlerTone.accent),
      // The brief marker's glyph, not the bell: a conversation, not an alarm.
      'asked' => (CarbonIcons.chat, HandlerTone.accent),
      'ask_rejected' => (CarbonIcons.chat, HandlerTone.warning),
      'answered' => (CarbonIcons.chat, HandlerTone.quiet),
      'item_done' => (CarbonIcons.checkmark, HandlerTone.success),
      'item_blocked' => (CarbonIcons.warning, HandlerTone.warning),
      'item_failed' => (CarbonIcons.error, HandlerTone.error),
      'item_skipped' => (CarbonIcons.close, HandlerTone.quiet),
      'instruction_dropped' => (CarbonIcons.warning, HandlerTone.quiet),
      // A key, not a shield: `armed` already owns the accent shield, and a feed
      // scanned one kind of row at a time cannot be asked to tell two identical
      // glyphs apart by what a session had already done. Permission, not alarm.
      'instruction_authorized' => (CarbonIcons.password, HandlerTone.accent),
      // The drawer's own Edit mark. A change the user made by hand and one
      // their sentence made for them are the same change to the same list, and
      // giving the second its own glyph would teach the pencil a second
      // meaning.
      'instruction_amended' => (CarbonIcons.edit, HandlerTone.accent),
      // The remit being tested. Shield in the warning tone, beside `armed`'s.
      'floor_warning' => (CarbonIcons.security, HandlerTone.warning),
      'evidence_rejected' => (CarbonIcons.warning, HandlerTone.warning),
      'wrapped_up' => (CarbonIcons.checkmark, HandlerTone.quiet),
      'parked' => (CarbonIcons.stop, HandlerTone.warning),
      'resumed' => (CarbonIcons.play, HandlerTone.quiet),
      _ => (null, null),
    };

/// Glyph ink uses the support colours, which are legible as a shape in a way
/// the same hues are not as small text.
Color _glyphColor(CarbonColors c, HandlerTone tone) => switch (tone) {
  HandlerTone.quiet || HandlerTone.secondary => c.iconSecondary,
  HandlerTone.accent => c.supportInfo,
  HandlerTone.success => c.supportSuccess,
  HandlerTone.warning => c.supportWarning,
  HandlerTone.error => c.supportError,
};

Widget? _activitySubtitle(HandlerActivityRecord r) {
  final detail = r.detail;
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
      return detail == null ? null : _NoteLine('→ $detail', null, code: true);
    case 'floor_warning':
    // Commands, absolute paths and hosts — read as data, never as prose, and the
    // only part of the row a user can check against what they meant to allow.
    case 'instruction_authorized':
      return detail == null ? null : _NoteLine(detail, null, code: true);
    case 'parked':
      // The bridge stamps the wake deadline into detail as an ISO instant.
      final wake = detail == null ? null : DateTime.tryParse(detail);
      return wake == null
          ? null
          : _NoteLine('resuming around ${dayAwareTime(wake)}', null);
    case 'escalate':
    case 'asked':
    case 'ask_rejected':
    case 'answered':
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
      return detail == null ? null : _NoteLine(detail, null);
    default:
      // A kind this build has no arm for — a bridge ahead of the app. The row
      // still says something (its reason is the title), so the fallback prints
      // whatever came with it rather than the protocol word, which is a name the
      // user has never seen and cannot act on.
      return detail == null ? null : _NoteLine(detail, null);
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.record, required this.meta});
  final HandlerActivityRecord record;
  final Widget meta;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final (title, titleTone) = _activityTitle(record);
    final (icon, iconTone) = _activityGlyph(record);
    final subtitle = _activitySubtitle(record);
    return CarbonContainedListRow(
      title: record.detail == null ? title : '$title. ${record.detail}',
      leading: HandlerRail(
        icon: icon,
        color: iconTone == null ? null : _glyphColor(colors, iconTone),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body.copyWith(
                    color: titleTone == null
                        ? colors.textPrimary
                        : colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: CarbonSpacing.spacing03),
              meta,
            ],
          ),
          ?subtitle,
        ],
      ),
    );
  }
}
