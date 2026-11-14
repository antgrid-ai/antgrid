import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../billing/pricing_visibility.dart';
import '../../design/ab_colors.dart';
import '../../models/handler_state.dart';

/// The Handler surface's shared status vocabulary — the words and colours every
/// surface uses to say what a session is doing. Kept in one place because the
/// header pill, the assistant bar and the Handler tab are all on screen at once
/// on desktop: two of them describing the same session in different words is
/// read as two different sessions.

/// How loudly a status is spoken, independent of any palette.
///
/// The Handler surface is painted by two design systems while it migrates, and
/// the words must not diverge between them: this is the one place a status is
/// given a tone, and each palette only resolves the tone to a colour.
enum HandlerTone { quiet, secondary, accent, success, warning, error }

/// Tone for one backlog item's status word.
HandlerTone handlerItemTone(String status) => switch (status) {
  'done' => HandlerTone.success,
  'failed' => HandlerTone.error,
  'blocked' => HandlerTone.warning,
  'active' => HandlerTone.accent,
  _ => HandlerTone.quiet,
};

/// A tone as text or glyph ink on a Carbon surface.
Color handlerToneColor(CarbonColors c, HandlerTone tone) => switch (tone) {
  HandlerTone.quiet => c.textHelper,
  HandlerTone.secondary => c.textSecondary,
  HandlerTone.accent => c.linkPrimary,
  HandlerTone.success => c.supportSuccess,
  HandlerTone.warning => c.supportCautionMajor,
  HandlerTone.error => c.textError,
};

/// A tone as a Carbon tag fill.
CarbonTagColor handlerToneTagColor(HandlerTone tone) => switch (tone) {
  HandlerTone.quiet => CarbonTagColor.gray,
  HandlerTone.secondary => CarbonTagColor.coolGray,
  HandlerTone.accent => CarbonTagColor.blue,
  HandlerTone.success => CarbonTagColor.green,
  HandlerTone.warning => CarbonTagColor.warmGray,
  HandlerTone.error => CarbonTagColor.red,
};

Color _abToneColor(AbColors p, HandlerTone tone) => switch (tone) {
  HandlerTone.quiet => p.textMuted,
  HandlerTone.secondary => p.textSecondary,
  HandlerTone.accent => p.accent,
  HandlerTone.success => p.success,
  HandlerTone.warning => p.warning,
  HandlerTone.error => p.error,
};

/// Palette for one backlog item's status word, on a surface still painted by
/// the Antgrid palette.
Color handlerItemStatusColor(AbColors p, String status) =>
    _abToneColor(p, handlerItemTone(status));

/// The status an item carries until something happens to it, which on a fresh
/// backlog is every row at once.
const handlerDefaultItemStatus = 'queued';

/// Floor for the status column, so `done` and `blocked` leave their item texts
/// on the same edge. The status word is a row's leading widget, and letting its
/// own length set the indent lines up no two items. Sized for the longest
/// status in today's vocabulary at the Carbon code size.
///
/// A floor, not a fixed width: `status` is parsed as free text and
/// [handlerItemTone] has a fallback arm, so a word this constant never
/// anticipated widens its own row rather than breaking across three lines
/// inside a fixed box.
const handlerStatusColumnWidth = CarbonSpacing.spacing09;

/// The column itself, so every word that stands in it — item status or not —
/// is one description of one thing. A row hand-rolling the same floor, tier and
/// alignment sits adjacent to these in one list, where half a point of drift
/// reads as a rendering bug.
Widget _statusColumn(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(minWidth: handlerStatusColumnWidth),
  child: Align(alignment: Alignment.centerRight, child: child),
);

Widget _statusWord(BuildContext context, String word, HandlerTone tone) {
  final theme = CarbonTheme.of(context);
  return Text(
    word,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: theme.typography.code.copyWith(
      color: handlerToneColor(theme.colors, tone),
    ),
  );
}

/// One backlog item's status, in a column of its own — for the Handler card,
/// where every item is one line and a column is the only place a second fact
/// can stand. The backlog drawer gives each item a line under its text and puts
/// the same word there, beside what happened; what stands in ITS leading column
/// is [HandlerRunNumber]. The words and the tones are shared either way, which
/// is what the surfaces owe each other — the same item described in two
/// vocabularies reads as two different items.
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
        : _statusWord(context, status, handlerItemTone(status)),
  );
}

/// The word an outstanding instruction wears while it is one. Deliberately the
/// verb the drawer's field and send button already use ("Send an instruction…",
/// "Send to Handler"), so the action is called the same thing at every step —
/// and a verb that stays true for a sentence taking a line off the list, which
/// "adding" beside a countermand promises the opposite of.
const handlerPendingInstructionLabel = 'sending';

/// Floor for the run-order column, so every item's text starts on the same edge
/// whether its number is 1 or 37. The number is a row's leading widget, and
/// letting its own width set the indent lines up no two items.
///
/// A floor, not a fixed width, for the reason [handlerStatusColumnWidth] is one:
/// a backlog long enough to run past three digits widens its own row rather than
/// clipping the one thing every dependency on the sheet points at.
const handlerRunNumberWidth = CarbonSpacing.spacing06;

/// The run-order column, so a number and the gap a row without one leaves are
/// one description of one thing.
///
/// LEFT-aligned, against the instinct to hang numerals in a right-aligned
/// gutter: every other line on this sheet — the section heading, the progress
/// label, the composer — starts on the same margin, and a number pushed to the
/// right edge of its column starts one pixel off the rail the quoted sentences
/// use. Close enough to read as a mistake rather than as a second column. The
/// text edge is held straight by the column's own width, so nothing is bought
/// by aligning the digits to each other instead.
Widget _runColumn(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(minWidth: handlerRunNumberWidth),
  child: Align(alignment: Alignment.centerLeft, child: child),
);

/// Where one item stands in the run order, tinted by what became of it.
///
/// Position is the fact every row has, no two rows share, and the queue is built
/// on: Handler works from the top, so the number says what it reaches next — and
/// it is the only short name a dependency can be pointed at by. Naming one costs
/// two digits here; naming it by its own text repeats a sentence already on
/// screen two rows up.
///
/// The status WORD is deliberately elsewhere on this surface. It rides on the
/// row's own line beside what happened, where a reader who wants it has room to
/// read it — and where a row with nothing to report spends no width saying so.
/// The column it used to stand in was blank on every `queued` row, which is most
/// rows for most of a session.
class HandlerRunNumber extends StatelessWidget {
  const HandlerRunNumber({
    super.key,
    required this.number,
    required this.status,
  });

  /// 1-based, the way the list is read and the way a dependency names it.
  final int number;

  /// Colours the number, so the state of the row is legible before its text is.
  /// Never spelled out here — see the class doc.
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return _runColumn(
      Text(
        '$number',
        maxLines: 1,
        softWrap: false,
        style: theme.typography.code.copyWith(
          color: handlerToneColor(theme.colors, handlerItemTone(status)),
        ),
      ),
    );
  }
}

/// The same column with nothing in it, for a row that has no place in the order
/// yet. Held rather than skipped: a sentence still being extracted has to start
/// on the same edge as the items it is about to become, and the word for what is
/// happening to it ([handlerPendingInstructionLabel]) goes where every other
/// row's status word goes.
class HandlerRunNumberGap extends StatelessWidget {
  const HandlerRunNumberGap({super.key});

  @override
  Widget build(BuildContext context) => _runColumn(const SizedBox.shrink());
}

/// What a run state is CALLED. `parked` is spoken as "Paused" everywhere — the
/// wire word is an implementation detail the user never asked about.
///
/// [asksOnly] splits the one state that has two meanings. `needs_you` is the
/// bridge's word for both "the session has stopped and is waiting on you" and
/// "the session is still working and has a question standing" — see
/// [HandlerSessionState.asksOnly], which reads the rows the capability gate has
/// already been over. Only the second is an ask, and calling it "Needs you"
/// tells the user their agent has stopped when it has not, which is the whole
/// distinction the ask exists to make.
String handlerRunStateLabel(HandlerRunState state, {bool asksOnly = false}) =>
    switch (state) {
      HandlerRunState.watching => 'Watching',
      HandlerRunState.handling => 'Handling',
      HandlerRunState.needsYou => asksOnly ? 'Asked you' : 'Needs you',
      HandlerRunState.parked => 'Paused',
    };

/// Tone for a run state. Accent is reserved for the two states that mean work
/// is moving or the user is wanted; watching is deliberately quiet, because it
/// is the state a session sits in for hours.
///
/// An ask drops to [HandlerTone.secondary] rather than to the quiet tier
/// `watching` gets: it is still something the user is expected to answer, so it
/// must not read as background, but it is not the stopped agent that earns the
/// accent. The tone is the only part of the split a user takes in without
/// reading, so it has to move with the word.
HandlerTone handlerRunStateTone(
  HandlerRunState state, {
  bool asksOnly = false,
}) => switch (state) {
  HandlerRunState.watching => HandlerTone.quiet,
  HandlerRunState.handling => HandlerTone.accent,
  HandlerRunState.needsYou =>
    asksOnly ? HandlerTone.secondary : HandlerTone.accent,
  HandlerRunState.parked => HandlerTone.warning,
};

/// [handlerRunStateTone] on a surface still painted by the Antgrid palette.
Color handlerRunStateColor(
  AbColors p,
  HandlerRunState state, {
  bool asksOnly = false,
}) => _abToneColor(p, handlerRunStateTone(state, asksOnly: asksOnly));

/// The word one armed session is reported with on a surface that stays on
/// screen, and the tone it is spoken in.
///
/// [handlerRunStateLabel] answers for the run state alone, and for three
/// sessions that answer is a lie. An agent that reports nothing the handler can
/// act on, and one whose monitoring has not come up or has gone down, both sit
/// at `watching` for as long as they stay armed — and "Watching" over a session
/// nobody is watching is the exact claim [HandlerObservability] and
/// [HandlerAvailability] exist to retire. The overrides live with the word
/// rather than at whichever surface remembered them.
///
/// Only `watching` is overridden, because the other three report something that
/// has already happened: a session cannot be handling a pause that never
/// reached the handler, so a coverage caveat there would describe its past
/// instead of its present.
({String label, HandlerTone tone}) handlerSessionStatusTone(
  HandlerSessionState session,
) {
  // `asksOnly` reads the rows the capability gate has already been over, so a
  // question this app has no way to answer keeps the loud word.
  final asksOnly = session.asksOnly;
  if (session.runState != HandlerRunState.watching) {
    return (
      label: handlerRunStateLabel(session.runState, asksOnly: asksOnly),
      tone: handlerRunStateTone(session.runState, asksOnly: asksOnly),
    );
  }
  if (session.observability == HandlerObservability.unsupported) {
    return (label: 'Not watched', tone: HandlerTone.warning);
  }
  return switch (session.availability?.state) {
    // Null is "nobody said" and keeps the ordinary word: an older bridge that
    // never reports availability must not read as a broken one.
    null || HandlerAvailabilityState.available => (
      label: handlerRunStateLabel(HandlerRunState.watching),
      tone: handlerRunStateTone(HandlerRunState.watching),
    ),
    HandlerAvailabilityState.unavailable => (
      label: 'Monitoring unavailable',
      tone: HandlerTone.warning,
    ),
    HandlerAvailabilityState.preparing || HandlerAvailabilityState.unknown => (
      label: 'Waiting for agent',
      tone: HandlerTone.warning,
    ),
  };
}

/// [handlerSessionStatusTone] on a surface still painted by the Antgrid
/// palette.
({String label, Color tone}) handlerSessionStatusWord(
  AbColors p,
  HandlerSessionState session,
) {
  final word = handlerSessionStatusTone(session);
  return (label: word.label, tone: _abToneColor(p, word.tone));
}

/// What a park is BLAMED on, in the words every surface that names one uses.
///
/// Reads [HandlerSessionState.parkCause] and never [HandlerSessionState.parkKind],
/// which is the whole point: the kind is the backoff policy the engine picked,
/// and everything that is not a provider limit is filed under `outage` —
/// Handler's own judge failing included. Rendering that as "provider outage"
/// tells a user whose agent is serving fine to go and debug their agent's
/// provider, over a stopped session Antgrid stopped itself.
///
/// The [parkKind] fallback is for a bridge that predates the cause, and says
/// only what `outage` genuinely knows — a failure the engine will retry — since
/// a bridge that sent no cause cannot tell whose failure it was. A cause a newer
/// bridge invents falls through to that same fallback rather than being spelled
/// out raw.
String? handlerParkReason(HandlerSessionState session) =>
    switch (session.parkCause) {
      'agent_limit' => 'rate limit',
      'agent_failure' => 'agent error',
      'judge_failure' => 'judge unavailable',
      _ => switch (session.parkKind) {
        'limit' => 'rate limit',
        'outage' => 'temporary failure',
        _ => null,
      },
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
  HandlerEntitlementReason.notEntitled when !kPricingSurfacesEnabled =>
    "Handler isn't available for this account yet.",
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
