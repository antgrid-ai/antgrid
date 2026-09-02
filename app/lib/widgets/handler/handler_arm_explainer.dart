import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../models/handler_state.dart';
import '../../providers/first_run.dart';
import '../../providers/providers.dart';
import '../../providers/session_opening_prompt.dart';
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

/// Shows the one-time "what is Handler" explainer, with the session's judge and
/// posture on it. Returns the edit to send with the arm, or null if the user
/// backed out.
///
/// A sheet rather than the confirm dialog it replaces, for one reason: this
/// screen already tells a user their judge cannot run headless, and until now it
/// offered nothing to do about it. The picker that fixes it belongs beside the
/// warning, and a title/body/two-buttons dialog has nowhere to put a control.
///
/// Still first-arm only — every later arm stays one tap, and the same controls
/// stay one tap away on the PA bar for the whole time a session is armed.
Future<HandlerSessionSettingsEdit?> showHandlerArmSheet(
  BuildContext context, {
  required String terminalId,
  required HandlerSessionSettingsValue initial,
  required bool? agentObservable,
  String? agentLabel,
  bool hasOpeningPrompt = false,
  bool? judgeCapable,
}) => showAbAdaptiveSheet<HandlerSessionSettingsEdit>(
  context,
  child: _ArmSheet(
    terminalId: terminalId,
    initial: initial,
    body: handlerArmExplainerBody(
      agentObservable: agentObservable,
      agentLabel: agentLabel,
      hasOpeningPrompt: hasOpeningPrompt,
      judgeCapable: judgeCapable,
    ),
  ),
);

class _ArmSheet extends StatefulWidget {
  const _ArmSheet({
    required this.terminalId,
    required this.initial,
    required this.body,
  });

  final String terminalId;
  final HandlerSessionSettingsValue initial;
  final String body;

  @override
  State<_ArmSheet> createState() => _ArmSheetState();
}

class _ArmSheetState extends State<_ArmSheet> {
  late HandlerSessionSettingsValue _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
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
              widget.body,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textSecondary,
              ),
            ),
          ),
          HandlerSessionSettings(
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
                  onTap: () => Navigator.of(context).maybePop(
                    handlerSessionSettingsEdit(widget.initial, _value),
                  ),
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
  HandlerSessionSettingsEdit? edit;
  if (!container.read(firstRunProvider).handlerArmedOnce) {
    edit = await showHandlerArmSheet(
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
    if (edit == null) return;
  }
  focusedServiceOrNull(container, (s) => s.handlerService)?.arm(
    terminalId: terminalId,
    goal: goal,
    judgeTool: edit?.judgeTool,
    judgeModel: edit?.judgeModel,
    personality: edit?.personality,
  );
  latchHandlerArmedOnConfirmation(container, terminalId);
}

/// How long to wait for the bridge's `handler:status` to list a just-armed
/// session before giving up on latching. Generous: a slow relay round-trip
/// must not read as a failed arm.
const kHandlerArmConfirmWindow = Duration(seconds: 30);

/// What a confirmed arm retires. Two things, both keyed on the bridge REPORTING
/// the session armed (its `handler:status` lists [terminalId]) rather than on
/// the send: the arm is fire-and-forget, and a dropped one must leave the next
/// attempt exactly what this one had.
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
/// [kHandlerArmConfirmWindow]; an unconfirmed arm simply retires nothing.
void latchHandlerArmedOnConfirmation(
  ProviderContainer container,
  String terminalId,
) {
  ProviderSubscription<AsyncValue<HandlerState>>? sub;
  Timer? timeout;
  bool confirmed(HandlerState? state) =>
      state?.sessions.containsKey(terminalId) ?? false;
  void latch() {
    timeout?.cancel();
    sub?.close();
    sub = null;
    container.read(sessionOpeningPromptsProvider.notifier).forget(terminalId);
    container.read(firstRunProvider.notifier).markHandlerArmed();
  }

  sub = container.listen(handlerStateProvider, (_, next) {
    if (confirmed(next.value)) latch();
  });
  timeout = Timer(kHandlerArmConfirmWindow, () {
    sub?.close();
    sub = null;
  });
  // The status may already list the session (re-arm race after a disarm the
  // bridge never processed) — check once so the latch doesn't wait on a
  // change that never comes.
  if (confirmed(container.read(handlerStateProvider).value)) latch();
}
