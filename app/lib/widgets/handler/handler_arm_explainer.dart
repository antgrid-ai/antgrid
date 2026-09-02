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
import '../../services/handler_service.dart';
import 'handler_instruction_composer.dart';
import 'handler_item_status.dart';
import 'handler_session_settings.dart';

/// Body copy for the first-arm explainer. Top-level so the copy matrix is
/// unit-testable without pumping a dialog.
///
/// The coverage line mirrors the catalog contract (see agentCatalogProvider):
/// `false` is a bridge saying "cannot watch" — reuse [unwatchableNotice], the
/// warning that otherwise lives only in the shield tooltip — while `null`
/// means nobody has said anything, so the copy claims neither.
///
/// [hasOpeningPrompt] announces the seeded goal: a backlog appears on its own
/// the moment such a session arms, and the sentence it came from was typed on a
/// different screen minutes earlier. Said once, before the coverage caveat — a
/// warning still reads last.
///
/// Withheld entirely from the `false` arm. Extraction still runs there, so the
/// sentence is mechanically true, but it promises a backlog two lines above the
/// notice saying arming would stay silent — and this is the one screen whose
/// whole job is to set the expectation before the user walks away. A session
/// that will say nothing has nothing to say about what it starts from.
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
String handlerArmExplainerBody({
  required bool? agentObservable,
  String? agentLabel,
  bool hasOpeningPrompt = false,
  bool? judgeCapable,
}) {
  const base =
      "Handler watches this session while you're away. When the agent pauses "
      'on a question or a permission, Handler answers what it safely can and '
      'queues the rest for you.';
  final head = hasOpeningPrompt
      ? '$base\n\nIt starts from what you asked for when you opened this '
            'session, and queues that as your backlog.'
      : base;
  return switch (agentObservable) {
    true => judgeCapable == false ? '$head\n\n$escalateOnlyNotice' : head,
    false => '$base\n\n${unwatchableNotice(agentLabel)}',
    null =>
      "$head\n\nThis agent hasn't reported what Handler can see here, so it "
          'may stay silent.',
  };
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

/// Shows the one-time "what is Handler" explainer, with the session's judge,
/// posture and an instruction composer on it. Returns what the user decided, or
/// null if they backed out.
///
/// A sheet rather than a dialog, for one reason: this screen tells a user their
/// judge cannot run headless, and the picker that fixes it belongs beside the
/// warning. A title/body/two-buttons dialog has nowhere to put a control.
///
/// Still first-arm only — every later arm stays one tap, and the same controls
/// stay one tap away on the PA bar for the whole time a session is armed.
Future<HandlerArmDecision?> showHandlerArmSheet(
  BuildContext context, {
  required String terminalId,
  required HandlerSessionSettingsValue initial,
  required bool? agentObservable,
  String? agentLabel,
  bool hasOpeningPrompt = false,
  bool? judgeCapable,
}) => showAbAdaptiveSheet<HandlerArmDecision>(
  context,
  child: _ArmSheet(
    terminalId: terminalId,
    initial: initial,
    hasOpeningPrompt: hasOpeningPrompt,
    agentObservable: agentObservable,
    agentLabel: agentLabel,
    judgeCapable: judgeCapable,
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
  });

  final String terminalId;
  final HandlerSessionSettingsValue initial;
  final bool? agentObservable;
  final String? agentLabel;

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
  /// The posture the sheet opens on. A fresh arm is the user CHOOSING one, so
  /// the seed is a real preset even where nothing has reported one yet — unlike
  /// the settings sheet, which reports what the far end holds and must show
  /// "not reported" rather than invent it.
  late HandlerSessionSettingsValue _value = (
    judgeTool: widget.initial.judgeTool,
    judgeModel: widget.initial.judgeModel,
    personality: widget.initial.personality ?? HandlerPersonality.watchdog,
  );
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
          ),
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
            onChanged: (next) => setState(() => _value = next),
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
                  onTap: () => Navigator.of(context).maybePop((
                    settings: handlerSessionSettingsEdit(
                      widget.initial,
                      _value,
                    ),
                    instruction: _instruction.text,
                  )),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The single first-arm flow, shared by the header shield and the away-moment
/// hint so the two can never drift: explainer while [FirstRunState.handlerArmedOnce]
/// is false → arm on confirm → latch the flag on EVERY successful arm.
///
/// Cancelling arms nothing and leaves the flag false, so the next tap explains
/// again — "never shown again" starts at the first successful arm. Takes a
/// [ProviderContainer], not a WidgetRef: the caller's widget may be gone by the
/// time the dialog resolves. [context] is only used before the await.
///
/// The goal comes from [sessionOpeningPromptsProvider] rather than from the
/// caller: both arm surfaces are one tap over a session the user did not have
/// to describe, and the sentence they started it with is the only statement of
/// intent that exists. Null when nothing was remembered — a session adopted at
/// launch, one started from an empty composer, or one already armed once — and
/// an omitted goal leaves the bridge's stored one untouched, so the payload-free
/// arm is still exactly what those sessions get.
///
/// The service is resolved AFTER the sheet, never captured before it: the sheet
/// stays open for as long as the user reads it, and a transport reconnect in
/// that window disposes the build-time instance, whose `arm` then returns having
/// sent nothing. The user tapped "Arm Handler", the sheet closed, and they walk
/// away believing the session is watched.
///
/// Every arm past the first sends no settings at all — the keys are omitted, the
/// bridge keeps what it has, and the tap stays a tap. The sheet's own edit is
/// likewise a DELTA: a control the user never touched sends nothing, so a first
/// arm cannot clear a judge pick the bridge holds and this app has not yet been
/// told about.
Future<void> armWithFirstRunExplainer({
  required BuildContext context,
  required ProviderContainer container,
  required String terminalId,
  required bool? agentObservable,
  String? agentLabel,
  bool? judgeCapable,
}) async {
  final goal = container.read(sessionOpeningPromptsProvider)[terminalId];
  HandlerArmDecision? decision;
  if (!container.read(firstRunProvider).handlerArmedOnce) {
    decision = await showHandlerArmSheet(
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
    );
    if (decision == null) return;
  }
  focusedServiceOrNull(container, (s) => s.handlerService)?.arm(
    terminalId: terminalId,
    goal: goal,
    judgeTool: decision?.settings.judgeTool,
    judgeModel: decision?.settings.judgeModel,
    personality: decision?.settings.personality,
  );
  latchHandlerArmedOnConfirmation(
    container,
    terminalId,
    instruction: decision?.instruction,
  );
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
/// [FirstRunState.handlerArmedOnce] — so a dropped send keeps the explainer, the
/// labeled shield and the away hint alive.
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
  // A re-tap while the bridge has not answered opens the first-run sheet again
  // — the flag that retires it is set only on confirmation, and the shield
  // still reads unarmed — so two latches can be live over one session and both
  // would fire on the same status, sending two instructions for one intended
  // arm. The newest supersedes.
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
    if (confirmed(next.value)) latch();
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
  // The navigator's OVERLAY, not its context: `Overlay.maybeOf` reads an
  // inherited marker planted inside each overlay entry, so it answers only
  // from within a mounted route. The navigator's own element sits above every
  // entry and resolves to null, which would make this whole path a silent
  // no-op — and there is no widget of ours alive here to ask instead.
  final overlay = container
      .read(rootNavigatorKeyProvider)
      .currentState
      ?.overlay;
  if (overlay == null) return;
  showAbToastOn(
    overlay,
    toast: AbToast(icon: AbIcons.warning, title: title, description: reason),
  );
}
