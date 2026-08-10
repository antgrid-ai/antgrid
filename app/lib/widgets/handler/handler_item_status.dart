import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../models/handler_state.dart';

/// The Handler surface's shared status vocabulary — the words and colours every
/// surface uses to say what a session is doing. Kept in one place because the
/// header pill, the assistant bar and the Handler tab are all on screen at once
/// on desktop: two of them describing the same session in different words is
/// read as two different sessions.

/// Palette for one backlog item's status word.
Color handlerItemStatusColor(AbColors p, String status) => switch (status) {
  'done' => p.success,
  'failed' => p.error,
  'blocked' => p.warning,
  'active' => p.accent,
  _ => p.textMuted,
};

/// The status an item carries until something happens to it, which on a fresh
/// backlog is every row at once.
const handlerDefaultItemStatus = 'queued';

/// Floor for the status column, so `done` and `blocked` leave their item texts
/// on the same edge. The status word is a row's leading widget, and letting its
/// own length set the indent lines up no two items. Sized for the longest
/// status in today's vocabulary at mono [AbTokens.fontXxs].
///
/// A floor, not a fixed width: `status` is parsed as free text and
/// [handlerItemStatusColor] has a fallback arm, so a word this constant never
/// anticipated widens its own row rather than breaking across three lines
/// inside a 44px box.
const handlerStatusColumnWidth = 44.0;

/// One backlog item's status, drawn identically on the Handler card and in the
/// backlog drawer — the same item described two ways on two surfaces of one
/// feature reads as two different items.
///
/// [handlerDefaultItemStatus] renders the column blank rather than writing the
/// word: printing it fills the column with one repeated value while saying
/// nothing the progress line ("2 left") hasn't, so a word here means something
/// changed. Right-aligned, so the status sits against the text it qualifies
/// instead of leaving a gap the length of its own word.
class HandlerItemStatusLabel extends StatelessWidget {
  const HandlerItemStatusLabel({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: handlerStatusColumnWidth),
      child: Align(
        alignment: Alignment.centerRight,
        child: status == handlerDefaultItemStatus
            ? const SizedBox.shrink()
            : Text(
                status,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXxs,
                  color: handlerItemStatusColor(context.antgrid, status),
                ),
              ),
      ),
    );
  }
}

/// What a run state is CALLED. `parked` is spoken as "Paused" everywhere — the
/// wire word is an implementation detail the user never asked about.
String handlerRunStateLabel(HandlerRunState state) => switch (state) {
  HandlerRunState.watching => 'Watching',
  HandlerRunState.handling => 'Handling',
  HandlerRunState.needsYou => 'Needs you',
  HandlerRunState.parked => 'Paused',
};

/// Tone for a run state. Accent is reserved for the two states that mean work
/// is moving or the user is wanted; watching is deliberately quiet, because it
/// is the state a session sits in for hours.
Color handlerRunStateColor(AbColors p, HandlerRunState state) => switch (state) {
  HandlerRunState.watching => p.textMuted,
  HandlerRunState.handling => p.accent,
  HandlerRunState.needsYou => p.accent,
  HandlerRunState.parked => p.warning,
};

/// Copy for the "this session cannot be watched" warning. [agentLabel] is the
/// agent's display name when the catalog named one; without it the warning
/// stays generic rather than inventing an attribution.
String unwatchableNotice(String? agentLabel) =>
    '${agentLabel ?? "This agent"} reports nothing the Handler can act on — '
    'arming it would stay silent.';

/// The other half of the same fact, and deliberately a different sentence: this
/// session IS watched, it just has no judge, so everything it pauses on reaches
/// the user. Collapsing the two into one "limited" message would hide which of
/// them the user is looking at.
const escalateOnlyNotice =
    "This judge can't run headless, so every pause comes to you.";

/// Statuses an item never leaves, so they are the ones that don't count as
/// remaining work.
const _terminalItemStatuses = {'done', 'skipped', 'failed'};

/// Aggregate backlog progress in one phrase, e.g. `1 of 3 done · 2 left`.
///
/// Only `done` counts towards the numerator, never the other terminal states: a
/// skipped or failed item ends without being achieved, and folding it into
/// progress is the summary inflation spec §4.3 guards against. `left` is
/// everything still open — queued, active and blocked alike — because from the
/// outside they are all work that has not happened yet.
String handlerProgressLabel(HandlerSessionState session) {
  final total = session.backlogTotal;
  if (total == 0) return 'Nothing queued';
  final done = session.backlogDone;
  final left = session.backlog
      .where((i) => !_terminalItemStatuses.contains(i.status))
      .length;
  final head = '$done of $total done';
  return left == 0 ? head : '$head · $left left';
}
