import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/handler_state.dart';
import '../../util/relative_time.dart';
import 'handler_ask_footer.dart';
import 'handler_blocked_action_card.dart';
import 'handler_decision_card.dart';
import 'handler_layout.dart';

/// Day-aware, not a bare clock: these rows are written while the user is away
/// and read afterwards, so they routinely span midnight.
String _fmtTime(int epochMs) =>
    dayAwareTime(DateTime.fromMillisecondsSinceEpoch(epochMs));

/// Right-aligned time metadata shown on escalation and activity rows.
///
/// The urgency and ask tests live on [HandlerRowMeta.forEscalation] rather than
/// at each call site: an escalation renders as one of three unrelated widgets
/// (blocked card, decision card, plain row) on two different surfaces, and a
/// derivation spelled out at each of those is that many chances to omit it —
/// with a fourth row shape starting life without it. A factory is what
/// forecloses that: the escalation goes in, the markers come out, and no caller
/// composes its own.
class HandlerRowMeta extends StatelessWidget {
  const HandlerRowMeta({
    super.key,
    required this.at,
    this.urgent = false,
    this.asked = false,
    this.inline = false,
  });

  /// The markers an escalation earns, derived once. Snapshots, wrap-ups and
  /// activity rows use the plain constructor — they are history, and nothing
  /// about them is waiting on the user.
  factory HandlerRowMeta.forEscalation(
    HandlerEscalation e, {
    bool inline = false,
  }) => HandlerRowMeta(
    at: e.at,
    urgent: e.urgency == 'high',
    asked: e.nonBlocking,
    inline: inline,
  );

  final int at;

  /// Only escalations pass this. Snapshots and activity rows are history, and
  /// nothing about them is waiting on the user.
  final bool urgent;

  /// The row is a question the session did not stop for. Also escalations only,
  /// and mutually exclusive with [urgent] by construction — an ask is always
  /// minted `normal` — so the precedence below is a floor rather than a case.
  final bool asked;

  /// One line instead of a stack, for the collapsed strip whose height is a
  /// fixed reserve.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final time = Text(
      _fmtTime(at),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: theme.typography.code.copyWith(color: theme.colors.textSecondary),
    );
    final Widget? tag = urgent
        ? const CarbonTag(
            label: 'Urgent',
            size: CarbonTagSize.small,
            color: CarbonTagColor.red,
          )
        : asked
        ? const CarbonTag(
            label: 'Asked',
            size: CarbonTagSize.small,
            color: CarbonTagColor.coolGray,
          )
        : null;
    if (inline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tag != null) ...[tag, const SizedBox(width: CarbonSpacing.spacing03)],
          Flexible(child: time),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Above the timestamp, so the eye reaches it on the way down rather
        // than after it. The word carries the meaning, not the fill, so the
        // two stay distinguishable without colour.
        //
        // One slot, so a row can never wear both words: Urgent wins, because a
        // row that somehow carried both would be a stopped session, and that is
        // the reading that must not be softened.
        ?tag,
        time,
      ],
    );
  }
}

/// One escalation, in whichever of its three shapes the row's own data asks
/// for.
///
/// Shared rather than copied because the same escalation is rendered on two
/// surfaces — the Handler tab's "Needs you" list and the agent panel's overlay
/// over the terminal the question stopped. A second hand-written copy of the
/// chain below is a fourth row shape by another name: it starts life with
/// whichever arm the author happened to need and drifts from there.
class HandlerEscalationRow extends StatelessWidget {
  const HandlerEscalationRow({
    super.key,
    required this.escalation,
    required this.backlog,
    this.onReply,
    this.onDismiss,
    this.onChoice,
    this.onAskOption,
  });

  final HandlerEscalation escalation;

  /// The OWNING session's backlog, as the caller currently holds it. The ask
  /// footer's claim is only checkable against that session's live items, and
  /// this widget is deliberately not given the state to look them up — so a
  /// caller that cannot resolve them hands over an empty list, which the footer
  /// reads as nothing running.
  final List<HandlerInstructionItem> backlog;

  /// Opens the free-text answer path — the reply sheet, the ask sheet, or the
  /// transcript, depending on the row. Null disables it, which is what a caller
  /// whose service has not resolved passes.
  final VoidCallback? onReply;

  /// Retires a `guard_blocked` report. Null disables the button; the report
  /// stays readable either way.
  final VoidCallback? onDismiss;

  /// Answers a quick choice by id, and reports whether it reached the wire —
  /// see [HandlerDecisionCard.onChoice] for why a false must not latch.
  final bool Function(String choiceId)? onChoice;

  /// The ask's own transport, with the same contract as [onChoice].
  final bool Function(String choiceId)? onAskOption;

  /// Built here rather than inside the widget that draws it, because the claim
  /// is only checkable against the owning session's live [backlog].
  Widget? get _askFooter => escalation.nonBlocking
      ? HandlerAskFooter(escalation: escalation, backlog: backlog)
      : null;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final e = escalation;
    // First in the chain, and a cheap floor rather than a live case: the bridge
    // never mints choices for a report, so this and the decision card can never
    // both want the row.
    if (e.kind == 'guard_blocked') {
      return HandlerBlockedActionCard(
        escalation: e,
        trailing: HandlerRowMeta.forEscalation(e),
        onDismiss: onDismiss,
        onReply: onReply,
      );
    }
    // An ask needs BOTH halves to draw buttons: the bridge clears `nonBlocking`
    // and `askOptions` together when it promotes one, so a row carrying only one
    // of them is a frame in flight and falls through to the plain row, which can
    // still answer it in words.
    if (e.choices != null || (e.nonBlocking && e.askOptions != null)) {
      return HandlerDecisionCard(
        escalation: e,
        trailing: HandlerRowMeta.forEscalation(e),
        footer: _askFooter,
        // The id, not the choice: the service resolves it against the
        // escalation's own offered set, so the text on the wire is always the
        // one the bridge authored.
        onChoice: onChoice,
        // The ask's own transport. It sends the id alone and nothing into the
        // session — the service refuses a row it cannot answer, which is what
        // the card reads as a refusal and declines to latch on.
        onAskOption: onAskOption,
        onCustomReply: onReply,
      );
    }
    final helper = theme.typography.helper.copyWith(
      color: colors.textSecondary,
    );
    // A pressable row announces only its title, so the title carries what the
    // content shows: the urgency word is what tells "Asked you" from "Needs
    // you" to a reader who cannot see the tag.
    return CarbonContainedListRow(
      title: [
        if (e.urgency == 'high')
          'Urgent'
        else if (e.nonBlocking)
          'Asked',
        e.question,
        if (e.floorRule != null) 'Safety floor: ${e.floorRule}',
        e.reasoning,
        if (e.nonBlocking) handlerAskLatencyNote,
      ].join('. '),
      leading: HandlerRail(
        icon: e.floorRule != null ? CarbonIcons.security : null,
        color: colors.supportWarning,
      ),
      onPressed: onReply,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // The question is the thing being decided, so it is allowed
                // the room to be read. Clipped at one line it was a decision
                // taken without its subject.
                child: Text(
                  e.question,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: CarbonSpacing.spacing03),
              HandlerRowMeta.forEscalation(e),
            ],
          ),
          if (e.floorRule != null)
            Text(
              'Safety floor: ${e.floorRule}',
              style: helper.copyWith(fontWeight: FontWeight.w600),
            ),
          Text(
            e.reasoning,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: helper,
          ),
          // An ask reaching this row is one with no options to tap —
          // answerable in words alone, and owed the same two things the card
          // gives it: what happens to the answer, and what is still running
          // behind it.
          if (e.nonBlocking) Text(handlerAskLatencyNote, style: helper),
          ?_askFooter,
        ],
      ),
    );
  }
}
