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

/// The column itself, so every word that stands in it — item status or not —
/// is one description of one thing. A row hand-rolling the same floor, tier and
/// alignment sits adjacent to these in one list, where half a point of drift
/// reads as a rendering bug.
Widget _statusColumn(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(minWidth: handlerStatusColumnWidth),
  child: Align(alignment: Alignment.centerRight, child: child),
);

Widget _statusWord(String word, Color color) => Text(
  word,
  maxLines: 1,
  softWrap: false,
  overflow: TextOverflow.ellipsis,
  style: AbTokens.monoStyle(fontSize: AbTokens.fontXxs, color: color),
);

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
  Widget build(BuildContext context) => _statusColumn(
    status == handlerDefaultItemStatus
        ? const SizedBox.shrink()
        : _statusWord(status, handlerItemStatusColor(context.antgrid, status)),
  );
}

/// The word an outstanding instruction wears while it is one. Deliberately the
/// verb the drawer's field and send button already use ("Send an instruction…",
/// "Send to Handler"), so the action is called the same thing at every step —
/// and a verb that stays true for a sentence taking a line off the list, which
/// "adding" beside a countermand promises the opposite of.
const handlerPendingInstructionLabel = 'sending';

/// The same column, for a sentence the bridge has not turned into items yet.
///
/// It lives beside the item vocabulary rather than in it: no item ever carries
/// this word, and taking [handlerItemStatusColor] would file the user's own
/// unextracted sentence under a status the bridge never wrote. What it does
/// share is the column — the sentence has to start on the same edge as every
/// real row's text, and that geometry is described here once.
class HandlerPendingLabel extends StatelessWidget {
  const HandlerPendingLabel({super.key});

  @override
  Widget build(BuildContext context) => _statusColumn(
    _statusWord(handlerPendingInstructionLabel, context.antgrid.textMuted),
  );
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
Color handlerRunStateColor(AbColors p, HandlerRunState state) =>
    switch (state) {
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

/// A plan name as the user meets it on their own billing surfaces, from the
/// lowercase label the token carries.
String _planLabel(String tier) =>
    tier.isEmpty ? tier : '${tier[0].toUpperCase()}${tier.substring(1)}';

/// Why Handler will not arm on this machine — the sentence a refusal is spoken
/// with, wherever it is spoken.
///
/// One string per reason, shared by the shield's tooltip and the sheet the
/// shield opens, for the reason this whole file exists: a user who hovers and
/// then taps must not be told two different things about one refusal.
///
/// Each sentence names the fix its own reason actually has, which is why the
/// two are not merged. `not_entitled` is a plan the user can change; the tier
/// is named when the bridge could read one, because "you are on Free" answers
/// a question "you need Pro" leaves open. `unreadable` is a machine whose
/// credentials stopped answering — an upgrade buys nothing there, and offering
/// one would sell a plan the user may already be paying for.
///
/// The null arm claims nothing beyond unavailability: a reason this app has no
/// sentence for still has to say that arming will not work, since silence is
/// the failure being fixed.
String handlerEntitlementNotice(HandlerEntitlement e) => switch (e.reason) {
  HandlerEntitlementReason.notEntitled =>
    e.tier == null
        ? 'Handler is part of Pro, and the plan this machine is signed in on '
              "doesn't include it."
        : 'Handler is part of Pro. This machine is signed in on the '
              '${_planLabel(e.tier!)} plan.',
  HandlerEntitlementReason.unreadable =>
    "Antgrid can't confirm this machine's plan, so Handler is held back. Sign "
        'out and back in on the computer running this project.',
  null => "Handler isn't available on this machine right now.",
};

/// What the shield says before it is pressed.
///
/// Top-level so the precedence is unit-testable without pumping the panel, the
/// same reason [handlerArmExplainerBody] is. This tooltip is the only surface
/// that answers before the shield is pressed at all: the arm sheet carries the
/// same facts, but only once the user has committed far enough to open it.
///
/// [observable] false outranks [judgeCapable] false: a session that reports
/// nothing cannot be watched, which makes what its judge could have done moot.
/// Either being null claims nothing, exactly as the catalog requires.
///
/// [entitlement] outranks both, and is outranked only by [armed]. Coverage
/// describes what an arm WOULD get, and a refused machine has no arm to get
/// it — but a session armed before the refusal is still the user's to disarm,
/// so that answer stays first.
String handlerShieldTooltip({
  required bool armed,
  required bool? observable,
  required bool? judgeCapable,
  String? agentLabel,
  HandlerEntitlement? entitlement,
}) {
  if (armed) return 'Disarm Handler';
  if (entitlement != null) return handlerEntitlementNotice(entitlement);
  if (observable == false) return unwatchableNotice(agentLabel);
  if (judgeCapable == false) return escalateOnlyNotice;
  return 'Arm Handler';
}

/// Statuses an item never leaves, so they are the ones that don't count as
/// remaining work.
const _terminalItemStatuses = {'done', 'skipped', 'failed'};

/// Aggregate backlog progress in one phrase, e.g. `1 of 3 done · 2 left`.
///
/// Only `done` counts towards the numerator, never the other terminal states: a
/// skipped or failed item ends without being achieved, and folding it into
/// progress is the summary inflation this guards against. `left` is
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
