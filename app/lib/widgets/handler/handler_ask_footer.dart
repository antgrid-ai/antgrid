import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../models/handler_state.dart';

/// What an ask promises about its own delivery, said before the answer is given
/// rather than as an apology afterwards.
///
/// Worded as a condition and never as a duration, because it is true in every
/// case Handler has: immediate when the agent is idle at a prompt, the next turn
/// boundary when it is working, and the next real event after a bridge restart.
const handlerAskLatencyNote =
    'Handler passes your answer on when it next hears from the agent.';

/// What the user is told when the work the question was supposed to be running
/// alongside has all stopped. [AbColors.warning], because the promise the ask
/// was raised on has quietly expired: from here the session is waiting on them
/// after all.
const handlerAskNothingRunningNote =
    'Nothing else is running — Handler is waiting on this';

/// Statuses that mean an item is not running.
///
/// `blocked` is in here and is NOT in the item vocabulary's own terminal set
/// (`handlerProgressLabel` counts it as work still left, because from the
/// outside it has not happened yet). Here the question is narrower and the
/// answer is the other one: a blocked item is work that has not MOVED, so
/// counting it as still-running is exactly the false reassurance this footer
/// exists to remove.
const _notRunningStatuses = {'done', 'skipped', 'failed', 'blocked'};

/// The "you can take your time" half of an ask, re-derived on every build.
///
/// One widget with two call sites — the decision card's footer slot and the
/// plain row an ask without options renders as — for the same reason the row
/// metadata is built in one place: an ask renders as more than one widget, and
/// a claim about what is still running must not be addable to one of them and
/// forgettable on the other.
///
/// [escalation]'s `unblocked` is a claim made when the question was raised,
/// never a count to be repeated: the ids are resolved against [backlog], the
/// owning session's live one, and only what SURVIVES that is spoken. An item
/// that has since finished costs the user a smaller number and never a wrong
/// one, and an ask whose work has all stopped says so instead of promising the
/// agent is still busy.
class HandlerAskFooter extends StatelessWidget {
  const HandlerAskFooter({
    super.key,
    required this.escalation,
    required this.backlog,
  });

  final HandlerEscalation escalation;

  /// The owning session's backlog, as the app currently holds it. Empty when no
  /// snapshot for that session has arrived yet, which reads as nothing running
  /// — the conservative answer, and the one that stops the footer claiming work
  /// it cannot see.
  final List<HandlerInstructionItem> backlog;

  /// Enough to say what the agent is doing without turning the card into a
  /// second backlog; the drawer already lists all of it.
  static const _maxItemRows = 3;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final gated = escalation.unblocked.toSet();
    final running = [
      for (final item in backlog)
        if (gated.contains(item.id) &&
            !_notRunningStatuses.contains(item.status))
          item,
    ];
    if (running.isEmpty) {
      return Text(
        handlerAskNothingRunningNote,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: p.warning,
        ),
      );
    }
    final hidden = running.length - _maxItemRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Still working on ${running.length} '
          'item${running.length == 1 ? '' : 's'}',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: p.textMuted,
          ),
        ),
        for (final item in running.take(_maxItemRows))
          Text(
            item.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: p.textSecondary,
            ),
          ),
        if (hidden > 0)
          Text(
            '+$hidden more',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
          ),
      ],
    );
  }
}
