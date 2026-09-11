import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_toast.dart';
import '../../models/handler_state.dart';
import '../../navigation/root_navigator.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/first_run.dart';
import '../../providers/providers.dart';
import '../../providers/session_opening_prompt.dart';
import '../../screens/upgrade_screen.dart';
import '../../services/handler_service.dart';
import 'handler_instruction_composer.dart';
import 'handler_item_status.dart';
import 'handler_session_settings.dart';

/// Body copy for the arm sheet, or null when there is nothing left to say —
/// which is the ordinary repeat arm over a covered agent. Top-level so the copy
/// matrix is unit-testable without pumping a dialog.
///
/// [explain] carries the standing "what is Handler" paragraph, and is false
/// once the user has armed anything (see [FirstRunState.handlerArmedOnce]).
/// Only that paragraph is dropped: this sheet opens on every arm, so its copy
/// would otherwise re-teach a user who has walked away and come back many
/// times. Everything below it is a fact about THIS arm — what will be queued,
/// what the agent will report — and none of it is retired by having read the
/// paragraph once.
///
/// The coverage line mirrors the catalog contract (see agentCatalogProvider):
/// `false` is a bridge saying "cannot watch" — reuse [unwatchableNotice], the
/// warning that otherwise lives only in the shield tooltip — while `null`
/// means nobody has said anything, so the copy claims neither.
///
/// [hasOpeningPrompt] announces the seeded goal: a backlog appears on its own
/// the moment such a session arms, and the sentence it came from was typed on a
/// different screen minutes earlier. Said before the coverage caveat — a
/// warning still reads last — and withheld entirely from the `false` arm, since
/// a session that will say nothing has nothing to say about what it starts
/// from. This is the one screen whose whole job is to set the expectation
/// before the user walks away.
///
/// [judgeCapable] is the second, independent half of the same coverage answer
/// — the session IS watched, but its judge cannot run headless, so every pause
/// reaches the user. The bridge already reports it post-arm as
/// `escalate_only`, on a chip found only after walking away and coming back.
///
/// On the `true` arm only, and only when the catalog said so outright. The
/// `false` arm already carries the stronger fact and stacking a second caveat
/// under it just dilutes the one that matters; the `null` arm has claimed
/// nothing about coverage and must not start here.
String? handlerArmExplainerBody({
  required bool? agentObservable,
  String? agentLabel,
  bool hasOpeningPrompt = false,
  bool? judgeCapable,
  bool explain = true,
}) {
  const base =
      "Handler watches this session while you're away. When the agent pauses "
      'on a question or a permission, Handler answers what it safely can and '
      'queues the rest for you.';
  // Names Handler outright rather than opening on "It", because the paragraph
  // that would have been its antecedent is gone on every arm past the first.
  const goal =
      'Handler starts from what you asked for when you opened this session, '
      'and queues that as your backlog.';
  final warning = switch (agentObservable) {
    true => judgeCapable == false ? escalateOnlyNotice : null,
    false => unwatchableNotice(agentLabel),
    null =>
      "This agent hasn't reported what Handler can see here, so it may stay "
          'silent.',
  };
  final paragraphs = [
    if (explain) base,
    // Withheld entirely from the unwatchable arm. Extraction still runs there,
    // so the sentence is mechanically true, but it promises a backlog directly
    // above the notice saying arming would stay silent.
    if (hasOpeningPrompt && agentObservable != false) goal,
    ?warning,
  ];
  return paragraphs.isEmpty ? null : paragraphs.join('\n\n');
}

/// What the arm sheet collected: a settings DELTA that rides the arm's
/// `handler:configure`, and a sentence that must NOT ride it at all.
///
/// A record rather than a widened edit because the two have different
/// destinations and different timing — the settings go out with the arm, the
/// instruction only after the bridge confirms it — and one type that could hold
/// either is one a call site can send down the wrong path. Null still means the
/// user backed out.
typedef HandlerArmDecision = ({
  HandlerSessionSettingsEdit settings,
  String instruction,
});

/// Shows the arm sheet — what Handler will do here, with the session's judge,
/// posture and an instruction composer on it. Returns what the user decided, or
/// null if they backed out.
///
/// A sheet rather than a dialog, for one reason: this screen tells a user their
/// judge cannot run headless, and the picker that fixes it belongs beside the
/// warning. A title/body/two-buttons dialog has nowhere to put a control.
///
/// Every arm opens it, not just the first: the sentence typed here is the only
/// backlog a session can be given AT arm time, and the coverage it warns about
/// is per-agent — so a user whose last arm was a watchable agent must still
/// meet an unwatchable one's notice on the next.
Future<HandlerArmDecision?> showHandlerArmSheet(
  BuildContext context, {
  required String terminalId,
  required HandlerSessionSettingsValue initial,
  required bool? agentObservable,
  String? agentLabel,
  bool hasOpeningPrompt = false,
  bool? judgeCapable,
  bool explain = true,
}) => showAbAdaptiveSheet<HandlerArmDecision>(
  context,
  child: _ArmSheet(
    terminalId: terminalId,
    initial: initial,
    hasOpeningPrompt: hasOpeningPrompt,
    agentObservable: agentObservable,
    agentLabel: agentLabel,
    judgeCapable: judgeCapable,
    explain: explain,
  ),
);

class _ArmSheet extends ConsumerStatefulWidget {
  const _ArmSheet({
    required this.terminalId,
    required this.initial,
    required this.hasOpeningPrompt,
    required this.agentObservable,
    required this.agentLabel,
    required this.judgeCapable,
    required this.explain,
  });

  final String terminalId;
  final HandlerSessionSettingsValue initial;
  final bool? agentObservable;
  final String? agentLabel;

  /// See [handlerArmExplainerBody]. Drops the standing explanation only; the
  /// coverage warnings and the seeded goal are per-arm facts and stay.
  final bool explain;

  /// Whether the judge this sheet OPENED on can run headless. The seed only —
  /// the body is recomputed against whatever judge is picked while it is up
  /// (see [_ArmSheetState.build]).
  final bool? judgeCapable;

  /// Steers the composer's hint alone. A seeded goal is already extracted on
  /// arm, and an instruction typed here is extracted a second time — nothing
  /// dedups across the two passes — so the sheet's job is to stop the user
  /// restating what it has just told them is already queued.
  final bool hasOpeningPrompt;

  @override
  ConsumerState<_ArmSheet> createState() => _ArmSheetState();
}

class _ArmSheetState extends ConsumerState<_ArmSheet> {
  /// What the sheet opens on, and the `from` side of its judge delta.
  ///
  /// The posture is seeded to a real preset even where nothing has reported one
  /// — unlike the settings sheet, which reports what the far end holds and must
  /// show "not reported" rather than invent it. This is the control the sheet
  /// exists for, and its unreported copy names a bridge too old to have the
  /// setting, which is a claim this surface has no grounds to make.
  ///
  /// That seed is a DISPLAY value and never a report, so it is not what the
  /// posture is sent against — see [_postureTouched]. The service cache is
  /// empty for a disarmed session after a restart while the bridge still holds
  /// the posture that session was last given, and treating the seed as the
  /// stored value would reset that pick to the default on every re-arm. The
  /// judge needs none of this, which is why it can diff normally: it is never
  /// seeded in the first place.
  late final HandlerSessionSettingsValue _opened = (
    judgeTool: widget.initial.judgeTool,
    judgeModel: widget.initial.judgeModel,
    personality: widget.initial.personality ?? HandlerPersonality.watchdog,
  );
  late HandlerSessionSettingsValue _value = _opened;

  /// Whether the user has TOUCHED the posture control, which is not the same
  /// question as whether the value ended up different. Moving off the seed and
  /// back is still a choice, and the seed it lands on may not be what the
  /// bridge holds — so any touch sends, and only an untouched control stays
  /// silent. A tap on the cell already selected never reaches here: AbSegmented
  /// swallows it, which is why this cannot simply be "the user tapped it".
  bool _postureTouched = false;
  final _instruction = TextEditingController();

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Recomputed on every build, never frozen at open: the composer's judge
    // chip is ON this sheet, so the escalate-only warning in this copy is one
    // the user can fix while reading it. A body computed once would keep
    // warning about a judge the sheet had already replaced, directly above the
    // control that replaced it.
    final effectiveJudge = handlerEffectiveJudge(
      ref,
      widget.terminalId,
      _value.judgeTool,
    );
    final body = handlerArmExplainerBody(
      agentObservable: widget.agentObservable,
      agentLabel: widget.agentLabel,
      hasOpeningPrompt: widget.hasOpeningPrompt,
      judgeCapable: effectiveJudge == null
          ? widget.judgeCapable
          : ref.watch(agentCatalogProvider)[effectiveJudge]?.judgeCapable,
      explain: widget.explain,
    );
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: abDialogTitlePadding,
            child: abDialogTitle(
              'Arm Handler',
              onClose: () => Navigator.of(context).maybePop(),
            ),
          ),
          // Absent on a repeat arm over a covered agent, where every sentence
          // this sheet could say has either been read already or would be a
          // claim about coverage nothing reported. The title and the composer
          // carry it from there.
          if (body != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space16,
                0,
                AbTokens.space16,
                AbTokens.space16,
              ),
              child: Text(
                body,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: p.textSecondary,
                ),
              ),
            )
          else
            // The title row carries no bottom padding of its own — a paragraph's
            // leading is what has always separated it from what follows.
            const SizedBox(height: AbTokens.space12),
          // Directly under the sentence about what gets queued, and above the
          // posture control: this box IS the act, and how much Handler handles
          // is a setting subordinate to it. No autofocus — the sheet is a thing
          // to read first, and a keyboard over it on a phone hides the copy
          // that explains what arming does.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbTokens.space16,
              0,
              AbTokens.space16,
              AbTokens.space16,
            ),
            child: HandlerInstructionComposer(
              terminalId: widget.terminalId,
              controller: _instruction,
              hintText: widget.hasOpeningPrompt
                  ? 'Anything to add beyond that?'
                  // The empty backlog's own invitation, verbatim: one act
                  // worded one way wherever the user meets it.
                  : "Add what you want done while you're away.",
              judge: (
                judgeTool: _value.judgeTool,
                judgeModel: _value.judgeModel,
              ),
              onJudgeChanged: (pick) => setState(
                () => _value = (
                  judgeTool: pick.judgeTool,
                  judgeModel: pick.judgeModel,
                  personality: _value.personality,
                ),
              ),
              judgeScopeNote: handlerJudgeScopeOnArm,
              // No send key: this sheet's one commit is [Arm Handler] below.
              send: null,
            ),
          ),
          // The judge rows stay off this sheet — the composer's chip is that
          // picker here, and mounting both would be two controls for one value.
          HandlerPostureControl(
            terminalId: widget.terminalId,
            value: _value,
            onChanged: (next) => setState(() {
              _value = next;
              _postureTouched = true;
            }),
          ),
          Padding(
            padding: const EdgeInsets.all(AbTokens.space16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AbButton(
                  label: 'Not now',
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: AbTokens.space8),
                AbButton(
                  label: 'Arm Handler',
                  variant: AbButtonVariant.primary,
                  onTap: () {
                    final edit = handlerSessionSettingsEdit(_opened, _value);
                    Navigator.of(context).maybePop((
                      settings: (
                        judgeTool: edit.judgeTool,
                        judgeModel: edit.judgeModel,
                        personality: _postureTouched
                            ? _value.personality
                            : null,
                      ),
                      instruction: _instruction.text,
                    ));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The single arm flow, shared by the header shield and the away-moment hint so
/// the two can never drift: sheet → arm on confirm → latch
/// [FirstRunState.handlerArmedOnce] on every successful arm.
///
/// Cancelling arms nothing. Takes a [ProviderContainer], not a WidgetRef: the
/// caller's widget may be gone by the time the sheet resolves. [context] is
/// re-checked with `context.mounted` past every await, because the refusal path
/// below shows a second surface after one.
///
/// The goal comes from [sessionOpeningPromptsProvider] rather than from the
/// caller: both arm surfaces sit over a session the user did not have to
/// describe, and the sentence they started it with is the only statement of
/// intent that exists. Null when nothing was remembered — a session adopted at
/// launch, one started from an empty composer, or one already armed once — and
/// an omitted goal leaves the bridge's stored one untouched, so a re-arm is
/// still exactly the payload-free arm those sessions want.
///
/// The service is resolved AFTER the sheet, never captured before it: the sheet
/// stays open for as long as the user reads it, and a transport reconnect in
/// that window disposes the build-time instance, whose `arm` then returns having
/// sent nothing. The user tapped "Arm Handler", the sheet closed, and they walk
/// away believing the session is watched.
///
/// What the sheet sends is a DELTA: a control the user never touched sends
/// nothing, so an arm cannot clear a judge or posture the bridge holds and this
/// app has not yet been told about.
Future<void> armWithSheet({
  required BuildContext context,
  required ProviderContainer container,
  required String terminalId,
  required bool? agentObservable,
  String? agentLabel,
  bool? judgeCapable,
}) async {
  // Asked BEFORE the arm sheet, never after: a sheet that cannot commit is a
  // form the user fills in only to be told it was never going to send.
  final refusal = focusedServiceOrNull(
    container,
    (s) => s.handlerService,
  )?.currentState.entitlement;
  if (refusal != null) {
    if (!await _showHandlerRefusal(context, refusal)) return;
    if (!context.mounted) return;
    await openUpgrade(context, container);
    if (!context.mounted) return;
    // Falls THROUGH into the ordinary arm rather than re-reading the refusal
    // it just showed: nothing re-emits a status frame when a device token is
    // re-minted, so the app's copy is at its stalest exactly here — the moment
    // after an upgrade. The bridge reads its verdict live at the arm, so
    // letting the arm run is what asks the only party that knows; a refusal
    // that still holds comes back on the frame that arm itself raises, and the
    // latch below is what speaks it.
  }
  final goal = container.read(sessionOpeningPromptsProvider)[terminalId];
  final decision = await showHandlerArmSheet(
    context,
    terminalId: terminalId,
    initial: handlerSessionSettingsFor(
      focusedServiceOrNull(container, (s) => s.handlerService),
      terminalId,
    ),
    agentObservable: agentObservable,
    agentLabel: agentLabel,
    hasOpeningPrompt: goal != null,
    judgeCapable: judgeCapable,
    explain: !container.read(firstRunProvider).handlerArmedOnce,
  );
  if (decision == null) return;
  focusedServiceOrNull(container, (s) => s.handlerService)?.arm(
    terminalId: terminalId,
    goal: goal,
    judgeTool: decision.settings.judgeTool,
    judgeModel: decision.settings.judgeModel,
    personality: decision.settings.personality,
  );
  latchHandlerArmedOnConfirmation(
    container,
    terminalId,
    instruction: decision.instruction,
  );
}

/// Says why Handler will not arm on this machine, and offers the one fix the
/// reason actually has. True when the user asked to see plans.
///
/// Only [HandlerEntitlementReason.notEntitled] offers that, because it is the
/// only refusal a purchase lifts. Every other reason gets a single Close: a
/// button that cannot help is worse than no button, since taking it teaches the
/// user the wrong thing about what went wrong.
///
/// A sheet rather than a toast: this is the answer to a deliberate press, it
/// carries an action, and a message that fades is how the press went unanswered
/// in the first place.
Future<bool> _showHandlerRefusal(
  BuildContext context,
  HandlerEntitlement entitlement,
) async =>
    await showAbAdaptiveSheet<bool>(
      context,
      child: _HandlerRefusalSheet(entitlement: entitlement),
    ) ??
    false;

class _HandlerRefusalSheet extends StatelessWidget {
  const _HandlerRefusalSheet({required this.entitlement});

  final HandlerEntitlement entitlement;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final upgradable =
        entitlement.reason == HandlerEntitlementReason.notEntitled;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: abDialogTitlePadding,
            child: abDialogTitle(
              // Names the plan on the one sheet that can sell it, and the state
              // on the one that cannot: a title promising Pro over a machine
              // whose credentials simply stopped answering points the user at a
              // purchase that changes nothing.
              upgradable ? 'Handler needs Pro' : 'Handler is unavailable',
              onClose: () => Navigator.of(context).maybePop(false),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbTokens.space16,
              0,
              AbTokens.space16,
              AbTokens.space16,
            ),
            child: Text(
              handlerEntitlementNotice(entitlement),
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textSecondary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbTokens.space16,
              0,
              AbTokens.space16,
              AbTokens.space16,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AbButton(
                  label: upgradable ? 'Not now' : 'Close',
                  onTap: () => Navigator.of(context).maybePop(false),
                ),
                if (upgradable) ...[
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: 'See plans',
                    variant: AbButtonVariant.primary,
                    onTap: () => Navigator.of(context).maybePop(true),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How long to wait for the bridge's `handler:status` to list a just-armed
/// session before giving up on latching. Generous: a slow relay round-trip
/// must not read as a failed arm.
const kHandlerArmConfirmWindow = Duration(seconds: 30);

/// How to cancel the latch in flight for a terminal, while one is. Keyed by
/// terminal rather than owned by a widget because the latch outlives every
/// widget involved: the sheet that started it is already popped, and the
/// session's own surfaces are what a user walks away from.
final _armLatches = <String, VoidCallback>{};

/// What a confirmed arm retires, and the one thing it releases. All of it is
/// keyed on the bridge REPORTING the session armed (its `handler:status` lists
/// [terminalId]) rather than on the send: the arm is fire-and-forget, and a
/// dropped one must leave the next attempt exactly what this one had.
///
/// [FirstRunState.handlerArmedOnce] — so a dropped send keeps the labeled
/// shield, the away hint and the sheet's explanatory paragraph alive.
///
/// The session's remembered opening prompt — so only a FIRST arm seeds a goal.
/// A plain disarm leaves the bridge nothing to rehydrate, so a re-arm carrying
/// the same sentence extracts it into an empty backlog again and Handler redoes
/// work it has already finished, unattended and past the undo offers the arm
/// itself retired. This runs on EVERY arm, not only the first: the flag is
/// global and the prompt is per session, and gating the second on the first is
/// how every install that has armed once keeps re-seeding.
///
/// The subscription self-cancels on confirmation or after
/// [kHandlerArmConfirmWindow]; an unconfirmed arm retires nothing — and says so
/// where an instruction was riding on it.
///
/// [instruction] is the arm sheet's typed text, and confirmation is the ONLY
/// moment it can be sent. `handler:instruct` reaching a bridge with no armed
/// session is dropped outright — logged to a stdout no phone reads — so the
/// same sentence issued beside the arm is lost, not queued. Nor may it ride the
/// arm as a goal: `instruct` is the one feed point for instruction-scoped
/// authorization, so the same words as a goal grant nothing and arrive as work
/// without the permission they imply.
void latchHandlerArmedOnConfirmation(
  ProviderContainer container,
  String terminalId, {
  String? instruction,
}) {
  // A re-tap while the bridge has not answered opens the sheet again — the
  // shield still reads unarmed — so two latches can be live over one session
  // and both would fire on the same status, sending two instructions for one
  // intended arm. The newest supersedes.
  //
  // It does NOT inherit the older one's sentence, because the reopened sheet
  // builds a fresh composer: the second pass is blank unless the user retypes.
  // So a superseded latch that was carrying words reports them lost rather than
  // dropping them silently — the replacement usually carries none, and this is
  // the only surface that ever held them.
  _armLatches.remove(terminalId)?.call();
  ProviderSubscription<AsyncValue<HandlerState>>? sub;
  Timer? timeout;
  void stop() {
    timeout?.cancel();
    timeout = null;
    sub?.close();
    sub = null;
  }

  bool confirmed(HandlerState? state) =>
      state?.sessions.containsKey(terminalId) ?? false;
  /// The other way an arm ends: the bridge answered, and its answer was no.
  /// Ends the latch the same way a confirmation does — nothing is retired, and
  /// the send is reported rather than left to time out in silence.
  void refuse(HandlerEntitlement entitlement) {
    _armLatches.remove(terminalId);
    stop();
    _reportArmRefused(container, entitlement, instruction);
  }

  void latch() {
    _armLatches.remove(terminalId);
    stop();
    container.read(sessionOpeningPromptsProvider.notifier).forget(terminalId);
    container.read(firstRunProvider.notifier).markHandlerArmed();
    _sendArmInstruction(container, terminalId, instruction);
  }

  _armLatches[terminalId] = () {
    stop();
    _reportArmInstructionLost(
      container,
      instruction,
      reason:
          'You re-armed before the first attempt was confirmed, so the '
          'instruction you typed with it was not sent.',
    );
  };
  sub = container.listen(handlerStateProvider, (_, next) {
    if (confirmed(next.value)) {
      latch();
      return;
    }
    // A frame carrying a refusal is the bridge saying so as of that frame, and
    // the refused arm raises one itself — so this answers within a round trip
    // instead of after the confirmation window. Only frames that ARRIVE count,
    // never the state already held: the refusal the user walked through to get
    // here is still sitting there, and reading it would report an arm that is
    // still in flight as dead.
    final entitlement = next.value?.entitlement;
    if (entitlement != null) refuse(entitlement);
  });
  timeout = Timer(kHandlerArmConfirmWindow, () {
    _armLatches.remove(terminalId);
    stop();
    _reportArmInstructionLost(container, instruction);
  });
  // The status may already list the session (re-arm race after a disarm the
  // bridge never processed) — check once so the latch doesn't wait on a
  // change that never comes.
  if (confirmed(container.read(handlerStateProvider).value)) latch();
}

/// Sends the arm sheet's sentence, once the bridge has confirmed the arm.
///
/// The service is RE-RESOLVED here and never captured across the sheet or the
/// latch window: this runs up to [kHandlerArmConfirmWindow] after the sheet
/// closed, and a transport reconnect in that window disposes the build-time
/// instance, whose `instruct` then sends nothing at all.
///
/// The three-valued result is honoured rather than discarded. `duplicate` is
/// reachable (a re-arm carrying the same sentence as one still outstanding) and
/// `empty` means no service resolved — on a screen the user is about to walk
/// away from, an unsent instruction must not look like a sent one.
void _sendArmInstruction(
  ProviderContainer container,
  String terminalId,
  String? text,
) {
  if (text == null || text.trim().isEmpty) return;
  final result =
      focusedServiceOrNull(
        container,
        (s) => s.handlerService,
      )?.instruct(terminalId, text) ??
      HandlerInstructResult.empty;
  switch (result) {
    case HandlerInstructResult.sent:
      return;
    // The arm IS confirmed on this path — it is the only thing that gets here —
    // so the send is what failed, and blaming the arm would point the user at a
    // session that is armed and watching.
    case HandlerInstructResult.empty:
      _reportArmInstructionLost(
        container,
        text,
        reason:
            'The connection dropped before your instruction went out, so it '
            'was not sent. The session is armed — send it again from the '
            'backlog.',
      );
    // Already outstanding, so the words ARE queued. Saying "nothing was queued"
    // here invites a re-send that stacks the same work twice.
    case HandlerInstructResult.duplicate:
      _reportArmInstructionLost(
        container,
        text,
        title: 'Already queued',
        reason: 'That instruction is already outstanding on this session.',
      );
  }
}

/// Says so when the sentence never made it.
///
/// An arm the bridge never confirms is indistinguishable from a dropped send —
/// a refused entitlement emits a status that does not list the session — so
/// without this the user's words vanish with no surface holding them, on the
/// one screen whose whole job is to set expectations before they walk away.
///
/// [reason] names what actually went wrong. The default is the timeout's — the
/// only caller that genuinely never saw a confirmation — because a toast that
/// blames the arm on a path where the arm succeeded sends the user looking in
/// the wrong place.
void _reportArmInstructionLost(
  ProviderContainer container,
  String? text, {
  String title = 'Nothing was queued',
  String reason =
      'Handler never confirmed the arm, so your instruction was not sent.',
}) {
  if (text == null || text.trim().isEmpty) return;
  _reportArmFailure(container, title: title, description: reason);
}

/// Says why an arm the bridge REFUSED went nowhere.
///
/// The one report on this flow that fires with no instruction riding on it: a
/// plain arm that is refused loses no words of the user's, so the refusal
/// itself is the whole of what there is to say — and saying nothing is what
/// makes a paid feature indistinguishable from a dropped tap.
void _reportArmRefused(
  ProviderContainer container,
  HandlerEntitlement entitlement,
  String? instruction,
) {
  final notice = handlerEntitlementNotice(entitlement);
  final lost = instruction != null && instruction.trim().isNotEmpty;
  _reportArmFailure(
    container,
    title: 'Handler not armed',
    description: lost
        ? '$notice The instruction you typed with it was not sent.'
        : notice,
  );
}

/// The one way this flow speaks once its widgets are gone.
///
/// The navigator's OVERLAY, not its context: `Overlay.maybeOf` reads an
/// inherited marker planted inside each overlay entry, so it answers only from
/// within a mounted route. The navigator's own element sits above every entry
/// and resolves to null, which would make this whole path a silent no-op — and
/// there is no widget of ours alive here to ask instead.
void _reportArmFailure(
  ProviderContainer container, {
  required String title,
  required String description,
}) {
  final overlay = container
      .read(rootNavigatorKeyProvider)
      .currentState
      ?.overlay;
  if (overlay == null) return;
  showAbToastOn(
    overlay,
    toast: AbToast(
      icon: AbIcons.warning,
      title: title,
      description: description,
    ),
  );
}
