import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../models/handler_state.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../util/relative_time.dart';
import 'handler_briefing_sheet.dart';
import 'handler_reply_sheet.dart';

String _fmtTime(int epochMs) =>
    clockTime(DateTime.fromMillisecondsSinceEpoch(epochMs));

class HandlerScreen extends ConsumerWidget {
  const HandlerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(handlerStateProvider).value;
    final p = context.antgrid;

    if (state == null || !state.anyArmed) {
      return Center(
        child: Text(
          'Handler is off — arm it on a session from the agent header.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: p.textMuted),
        ),
      );
    }

    final service = serviceWhenReady(ref, handlerServiceProvider);
    // Read in build, not inside editBrief: that callback runs after an await on
    // the sheet and the row that opened it can be gone by then.
    final judgeTools = ref.watch(judgeCapableToolsProvider);

    final entries = {
      for (final s in ref.watch(activeSessionsProvider)) s.id: s,
    };
    String nameOf(String terminalId) =>
        entries[terminalId]?.name ?? terminalId;
    // The PRE-arm half of the coverage question, for a bridge too old to report
    // per-session observability. A SessionEntry carries `tool` only when it
    // OVERRODE the project default, so an absent one resolves to defaultTool —
    // the same resolution the bridge's own observable() thunk does.
    final catalog = ref.watch(agentCatalogProvider);
    String? agentOf(String terminalId) =>
        entries[terminalId]?.tool ?? state.defaultTool;
    bool? agentObservableOf(String terminalId) => handlerObservableFromCatalog(
      catalog,
      agentOf(terminalId),
      chat: entries[terminalId]?.mode == 'chat',
    );
    // Show which session a row belongs to only when the screen is actually
    // mixing rows from more than one terminal — a single-session handler
    // repeating the same label on every row is noise.
    final distinctTerminals = <String>{
      ...state.sessions.keys,
      ...state.escalations.map((e) => e.terminalId),
      ...state.activity.map((a) => a.terminalId),
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
      service.reply(e, text);
    }

    Future<void> editBrief(HandlerSessionState s) async {
      if (service == null) return;
      final choice = await showHandlerBriefingSheet(
        context,
        terminalId: s.terminalId,
        service: service,
        judgeTools: judgeTools,
        initialBrief: s.brief,
        initialNotifyOnly: s.notifyOnly,
        observability: s.observability,
        agentObservable: agentObservableOf(s.terminalId),
        agentLabel: catalog[agentOf(s.terminalId)]?.label,
      );
      if (choice == null) return;
      if (choice.disarm) {
        service.disarm(s.terminalId);
      } else {
        service.arm(
          terminalId: s.terminalId,
          brief: choice.brief,
          notifyOnly: choice.notifyOnly,
          judgeTool: choice.judgeTool,
          judgeModel: choice.judgeModel,
        );
      }
    }

    return ListView(
      children: [
        for (final s in state.sessions.values)
          _SessionBriefHeader(
            session: s,
            sessionName: showSessionLabels ? nameOf(s.terminalId) : null,
            // The sessionNames watch above already subscribes this build to
            // session-list changes, so the resolver read stays reactive. The
            // bare state.defaultTool is NOT a second resolution rule — it only
            // fires while the service is still resolving (the resolver already
            // includes it when the service is up).
            judgeLabel:
                s.judgeTool ??
                service?.resolvedDefaultTool(s.terminalId) ??
                state.defaultTool ??
                'default',
            onTap: () => editBrief(s),
          ),
        if (state.escalations.isNotEmpty) ...[
          _SectionHeader(label: 'Needs you', color: p.accent),
          for (final e in state.escalations)
            AbListRow(
              leading: e.floorRule != null
                  ? AbIcon(AbIcons.shield, size: 14, color: p.warning)
                  : null,
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
              trailing: _RowMeta(
                sessionName: showSessionLabels ? nameOf(e.terminalId) : null,
                at: e.at,
                p: p,
              ),
              onTap: () => answer(e),
            ),
        ],
        _SectionHeader(label: 'Activity', color: p.textMuted),
        if (state.activity.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AbTokens.space16),
            child: Text(
              'No activity yet.',
              style: AbTokens.sansStyle(color: p.textMuted),
            ),
          )
        else
          for (final a in state.activity)
            _ActivityRow(
              record: a,
              sessionName: showSessionLabels ? nameOf(a.terminalId) : null,
              p: p,
            ),
      ],
    );
  }
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

/// Tappable contract header for one armed session: task summary, the
/// completion condition, then-follow-up progress, and the satisfied-ledger
/// trail. Tapping reopens the briefing sheet for a mid-flight edit.
class _SessionBriefHeader extends StatelessWidget {
  const _SessionBriefHeader({
    required this.session,
    required this.sessionName,
    required this.judgeLabel,
    required this.onTap,
  });
  final HandlerSessionState session;
  final String? sessionName;

  /// Resolved judge CLI for the read-only chip (override, else the session's
  /// default). Editing goes through the briefing sheet — this never mutates.
  final String judgeLabel;
  final VoidCallback onTap;

  // Only the newest few ledger entries render inline — a long-running session
  // can satisfy dozens of items and the header must stay a header, not a log.
  static const _maxLedgerRows = 3;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final brief = session.brief;
    final doneWhen = brief.doneWhen;
    final hiddenLedger = session.ledger.length - _maxLedgerRows;
    final visibleLedger = hiddenLedger > 0
        ? session.ledger.sublist(hiddenLedger)
        : session.ledger;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AbTokens.space16,
          AbTokens.space12,
          AbTokens.space16,
          AbTokens.space12,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.borderSubtle)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sessionName != null) ...[
              Text(
                sessionName!,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXxs,
                  color: p.textMuted,
                ),
              ),
              const SizedBox(height: AbTokens.space2),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    brief.taskSummary,
                    style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: AbTokens.space8),
                // Sits beside the judge chip because that is what it qualifies:
                // the named judge cannot run headless, so nothing it sees gets
                // answered without the user.
                if (session.observability == HandlerObservability.escalateOnly)
                  ...[
                    AbChip.system(label: 'ESCALATE ONLY', color: p.warning),
                    const SizedBox(width: AbTokens.space6),
                  ],
                AbChip.label(label: judgeLabel, color: p.textMuted),
              ],
            ),
            // Only ever rendered from the session's OWN report: a bridge that
            // sends no observability leaves this silent rather than guessing
            // from the agent it happens to run.
            if (session.observability == HandlerObservability.unsupported) ...[
              const SizedBox(height: AbTokens.space4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AbIcon(AbIcons.warning, size: 12, color: p.warning),
                  const SizedBox(width: AbTokens.space4),
                  Expanded(
                    child: Text(
                      'Not watched — this agent reports nothing the Handler '
                      'can act on.',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (doneWhen != null && doneWhen.isNotEmpty) ...[
              const SizedBox(height: AbTokens.space4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (session.doneWhenMet) ...[
                    AbIcon(AbIcons.check, size: 12, color: p.success),
                    const SizedBox(width: AbTokens.space4),
                  ],
                  Expanded(
                    child: Text(
                      doneWhen,
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontXs,
                        color: session.doneWhenMet ? p.success : p.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (session.thenTotal > 0) ...[
              const SizedBox(height: AbTokens.space4),
              Text(
                '${session.thenSatisfied} of ${session.thenTotal} follow-ups done',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
            ],
            if (hiddenLedger > 0) ...[
              const SizedBox(height: AbTokens.space2),
              Text(
                '… $hiddenLedger earlier',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
            ],
            for (final entry in visibleLedger) ...[
              const SizedBox(height: AbTokens.space2),
              Text(
                '${entry.item} — ${entry.evidence}',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.record,
    required this.sessionName,
    required this.p,
  });
  final HandlerActivityRecord record;
  final String? sessionName;
  final AbColors p;

  @override
  Widget build(BuildContext context) {
    final meta = _RowMeta(sessionName: sessionName, at: record.at, p: p);
    switch (record.decision) {
      case 'brief_armed':
        return AbListRow(
          title: Text('Armed', style: AbTokens.sansStyle()),
          trailing: meta,
        );
      case 'brief_edited':
        return AbListRow(
          title: Text('Brief edited', style: AbTokens.sansStyle()),
          trailing: meta,
        );
      case 'handle':
        return AbListRow(
          title: Text(
            'Auto-answered: ${record.reason}',
            style: AbTokens.sansStyle(),
          ),
          subtitle: record.detail != null
              ? Text(
                  '→ ${record.detail}',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                )
              : null,
          trailing: meta,
        );
      case 'escalate':
        return AbListRow(
          title: Text(
            'Escalated: ${record.reason}',
            style: AbTokens.sansStyle(),
          ),
          subtitle: record.detail != null
              ? Text(
                  record.detail!,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                )
              : null,
          trailing: meta,
        );
      case 'item_satisfied':
        return AbListRow(
          title: Text(
            'Satisfied: ${record.reason}',
            style: AbTokens.sansStyle(),
          ),
          subtitle: record.detail != null
              ? Text(
                  record.detail!,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                )
              : null,
          trailing: meta,
        );
      case 'wrapped_up':
        return AbListRow(
          title: Text('Wrapped up', style: AbTokens.sansStyle()),
          trailing: meta,
        );
      case 'parked':
        // The bridge stamps the wake deadline into detail as an ISO instant.
        final wake = record.detail == null
            ? null
            : DateTime.tryParse(record.detail!);
        return AbListRow(
          title: Text('Paused: ${record.reason}', style: AbTokens.sansStyle()),
          subtitle: wake == null
              ? null
              : Text(
                  'resuming around ${clockTime(wake)}',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                ),
          trailing: meta,
        );
      case 'resumed':
        return AbListRow(
          title: Text('Resumed: ${record.reason}', style: AbTokens.sansStyle()),
          trailing: meta,
        );
      default:
        return AbListRow(
          title: Text(record.reason, style: AbTokens.sansStyle()),
          subtitle: Text(
            record.decision,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
          ),
          trailing: meta,
        );
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        AbTokens.space4,
      ),
      child: Text(
        label.toUpperCase(),
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
