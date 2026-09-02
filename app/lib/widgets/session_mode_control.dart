import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../models/agent_work_status.dart';
import '../models/session_entry.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_catalog.dart';
import '../providers/agent_transport.dart';
import '../providers/focused_tools.dart';
import '../providers/new_session_picker.dart';
import '../providers/session_mode.dart';
import '../providers/sessions.dart';
import '../services/sessions_service.dart';
import '../util/detached.dart';
import 'mode_segmented.dart';
import 'session_agent_mark.dart';

/// Switches the focused session between terminal and chat.
///
/// [ModeSegmented] at header density: both options visible, the live one
/// accented, labels demoted to tooltips. A single destination glyph would be
/// narrower still, but a header that also carries a [SessionAgentMark] can't
/// afford a second unlabelled glyph whose meaning is "the thing you are NOT
/// looking at" — and the box, divider and accent fill are what make a
/// two-state choice legible without a caption.
///
/// The two ways this can be unavailable are answered differently on purpose.
/// A conversation that can no longer be resumed
/// ([SessionEntry.agentSessionResumable]) hides the whole control — it is
/// transient, per-session, and there is no honest short copy for "the
/// conversation this would carry over is gone". An agent with no chat driver —
/// or one nothing has yet described, which carries its own copy — is permanent
/// and knowable, so the Chat cell stays visible and greyed, carrying the reason;
/// `AbSegmented` keeps disabled cells hit-testing precisely so that reason
/// survives on phones, which have no hover.
///
/// Mounted in BOTH the mobile agent-panel header and the desktop window title
/// bar (which replaced that header) — either one alone ships the feature to
/// half the platforms.
class SessionModeControl extends ConsumerWidget {
  const SessionModeControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeSessionProvider);
    if (active == null || !active.agentSessionResumable) {
      return const SizedBox.shrink();
    }
    final pending = ref.watch(pendingSessionModeProvider);
    final inFlight = pending?.sessionId == active.id;
    // Anything that isn't chat is a terminal: the selected value has to match a
    // cell exactly, and an unknown mode string must not leave both unlit.
    final mode = (ref.watch(activeSessionModeProvider) ?? active.mode) == 'chat'
        ? 'chat'
        : 'terminal';
    final chatCapable = ref.watch(focusedToolChatCapableProvider(active.tool));
    final agent =
        ref.watch(focusedMachineToolsProvider).value?.labels[active.tool] ??
        sessionAgentDisplayLabel(active, ref.watch(agentCatalogProvider));
    // A session RUNNING in chat mode is its own proof that its agent can, and
    // that proof outranks every advert: greying the cell the session is
    // currently sitting in would say the mode you are looking at is impossible.
    final chatEnabled = mode == 'chat' || chatCapable == true;

    final control = ModeSegmented(
      keyPrefix: 'session-mode',
      mode: mode,
      iconOnly: true,
      chatEnabled: chatEnabled,
      // An unanswered capability says so rather than blaming the agent: the
      // cell is dead either way, but only one of the two is fixable by
      // updating the machine's bridge — and an answer that simply hasn't
      // arrived yet must not be reported as an old bridge.
      chatDisabledReason: chatCapable == null
          ? "This machine hasn't said whether $agent supports chat sessions — "
                'it may still be connecting, or its bridge may be too old to '
                'answer.'
          : "$agent doesn't support chat sessions.",
      // Both cells inert while a flip is in flight, so a second tap can't queue
      // a second one. No reason attached: the user just tapped.
      enabled: !inFlight,
      onChanged: (target) => detached(
        'SessionModeControl',
        'switch session mode',
        () => _switchMode(context, ref.container, active, target),
      ),
    );
    // Dimming a control whose whole job is to look chooseable reads as broken,
    // so the pending state pulses instead.
    return inFlight ? PulsingOpacity(child: control) : control;
  }
}

/// [SessionModeControl]'s state, redone as a single [AbLiveMenuRow] for a
/// text-menu host (the mobile overflow popup) instead of a segmented
/// control. A menu row has no room to show the option NOT being picked, so
/// the label names the action ("Switch to Terminal"/"Switch to Chat")
/// instead of the two-state choice. Same visibility/capability rules as
/// [SessionModeControl] — keep the two in lockstep by hand; neither is a
/// special case of the other's build method.
class SessionModeMenuItem extends ConsumerWidget {
  const SessionModeMenuItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeSessionProvider);
    if (active == null || !active.agentSessionResumable) {
      return const SizedBox.shrink();
    }
    final pending = ref.watch(pendingSessionModeProvider);
    final inFlight = pending?.sessionId == active.id;
    final mode = (ref.watch(activeSessionModeProvider) ?? active.mode) == 'chat'
        ? 'chat'
        : 'terminal';
    final target = mode == 'chat' ? 'terminal' : 'chat';
    final chatCapable = ref.watch(focusedToolChatCapableProvider(active.tool));
    final agent =
        ref.watch(focusedMachineToolsProvider).value?.labels[active.tool] ??
        sessionAgentDisplayLabel(active, ref.watch(agentCatalogProvider));
    final chatEnabled = mode == 'chat' || chatCapable == true;
    // Switching TO terminal is always reachable; switching to chat carries
    // the same capability gate as the segmented control's Chat cell.
    final targetEnabled = target == 'terminal' || chatEnabled;

    final row = AbLiveMenuRow(
      label: target == 'chat' ? 'Switch to Chat' : 'Switch to Terminal',
      icon: target == 'chat' ? AbIcons.comment : AbIcons.terminal,
      enabled: targetEnabled,
      disabledReason: chatCapable == null
          ? "This machine hasn't said whether $agent supports chat sessions — "
                'it may still be connecting, or its bridge may be too old to '
                'answer.'
          : "$agent doesn't support chat sessions.",
      onTap: () {
        // Inert while a flip is in flight, so a second tap can't queue a
        // second one — same contract as SessionModeControl.
        if (inFlight) return;
        // The popup route closes BEFORE the confirm dialog opens. This row is
        // the content of a `showAbPanel` PopupRoute, which its own doc says
        // pops itself; leaving it up stacks the dialog over a live modal
        // barrier and then leaves the menu covering the session it just
        // changed. The dialog anchors on the NAVIGATOR's context, which
        // outlives the route being popped, and the container is read before
        // the pop for the same reason.
        final navigator = Navigator.of(context);
        final host = navigator.context;
        final container = ref.container;
        navigator.pop();
        detached(
          'SessionModeMenuItem',
          'switch session mode',
          () => _switchMode(host, container, active, target),
        );
      },
    );
    return inFlight ? PulsingOpacity(child: row) : row;
  }
}

/// Marker text of the `session:set-mode` failure where the old runtime never
/// shut down. Kept in lockstep with `TEARDOWN_TIMEOUT_ERROR` in
/// bridge/src/session-manager.ts.
///
/// Matched with `contains`, never `startsWith`: the bridge reports the reason as
/// `String(err)` on a thrown `Error`, so the wire text is prefixed with
/// `"Error: "` and an anchored match silently never fires.
const kTeardownTimeoutError = 'timed out tearing down session';

/// Marker text of the `session:set-mode` failure where the old runtime shut down
/// but the new one wouldn't start. Kept in lockstep with `RESTART_FAILED_ERROR`
/// in bridge/src/session-manager.ts. Same `contains` matching as above.
///
/// These two are the only refusals that leave the session STOPPED; every other
/// one leaves it running in its original mode.
const kRestartFailedError = 'failed to restart session after mode switch';

/// What this session stands to lose by restarting right now, or null when it
/// has nothing in flight and the plain idle copy applies.
///
/// Gated on the session's OWN status. The project-level status fires while a
/// sibling session works, so warning off it would be wrong about half the time
/// — which teaches the user to click through the warning that isn't.
///
/// `attention` and `working` are not one warning. An agent blocked on a prompt
/// loses the pending call outright (a resume does not re-ask it); a churning
/// agent only loses the turn it is mid-way through. A null status means the
/// bridge didn't say, so promise nothing about what survives.
String? _modeSwitchWarning(AgentWorkStatus? status, String agent) =>
    switch (status) {
      AgentWorkStatus.attention =>
        '$agent is waiting on you. Switching restarts it, so whatever it is '
            "waiting on is dropped — it won't be asked again. Everything "
            'before it carries over.',
      AgentWorkStatus.working =>
        '$agent is still replying. Switching restarts it, so that reply is '
            'lost. Everything before it carries over.',
      // Unread is a read state, not work in flight: whatever the switch would
      // restart, the turn behind it already finished.
      AgentWorkStatus.done ||
      AgentWorkStatus.unread ||
      AgentWorkStatus.error ||
      null => null,
    };

Future<void> _switchMode(
  BuildContext context,
  ProviderContainer container,
  SessionEntry session,
  String target,
) async {
  // Takes the container, never a `WidgetRef`: the focused project can
  // re-resolve while the dialog is open, and one caller pops its own popup
  // route before getting here — a ref read past either point throws.
  // Everything downstream goes through it so an unmount mid-flip still clears
  // `pending`.
  final agent =
      container.read(focusedMachineToolsProvider).value?.labels[session.tool] ??
      sessionAgentDisplayLabel(session, container.read(agentCatalogProvider));

  final warning = _modeSwitchWarning(session.workStatus, agent);
  final confirmed = await AbConfirmDialog.show(
    context: context,
    title: 'Switch to $target?',
    // A stopped session is not restarted by the flip (setMode only re-launches
    // what was running), so promising a restart there would be wrong. Every
    // `warning` implies a live runtime, so only the idle copy has to branch.
    body:
        warning ??
        (session.running
            ? 'Switching restarts $agent. Your conversation carries over.'
            : 'Your conversation carries over the next time you start it.'),
    // "Switch anyway" only over a warning — the label has to read as
    // overriding something, or it stops meaning anything when it matters.
    confirmLabel: warning == null ? 'Switch to $target' : 'Switch anyway',
  );
  if (!confirmed) return;

  // Nullable read, not `sessionsServiceProvider`: that façade throws while the
  // project session re-resolves. Same shape the rename paths use.
  //
  // Answered, not swallowed: unlike the rename paths this is reached AFTER a
  // confirmation the user already gave, and a confirmed action that does
  // nothing and says nothing is indistinguishable from a dropped tap.
  final projectId = container.read(selectedRegistrationIdProvider);
  final service = projectId == null
      ? null
      : container
            .read(projectSessionProvider(projectId))
            .value
            ?.sessionsService;
  if (service == null) {
    if (context.mounted) {
      showAbSnackBar(
        context,
        "Couldn't switch to $target — this project isn't connected yet. Try "
        'again in a moment.',
      );
    }
    return;
  }

  final pending = container.read(pendingSessionModeProvider.notifier);
  final ours = PendingSessionMode(sessionId: session.id, mode: target);
  pending.set(ours);
  SessionModeResult result;
  try {
    result = await service.setMode(session.id, target);
  } catch (e) {
    result = (ok: false, error: '$e');
  } finally {
    // Retract only our own. The slot is app-wide, so a flip started on ANOTHER
    // session while this one was in flight now owns it — clearing that would
    // drop its panel back to the old view and re-enable its toggle mid-flight.
    if (container.read(pendingSessionModeProvider) == ours) pending.set(null);
  }
  if (result.ok || !context.mounted) return;
  final error = result.error ?? '';
  final String body;
  if (error.contains(kTeardownTimeoutError)) {
    body =
        "Couldn't switch to $target — $agent didn't shut down. The session is "
        'stopped; try starting it again.';
  } else if (error.contains(kRestartFailedError)) {
    body =
        "Couldn't switch to $target — $agent shut down but wouldn't start "
        'again. The session is stopped in ${session.mode} mode; try starting '
        'it again.';
  } else {
    // Every other refusal (archived, gone, no driver) leaves the runtime
    // untouched, so telling the user to restart it would be a lie.
    body =
        "Couldn't switch to $target. The session is still in "
        '${session.mode} mode.';
  }
  // A snack bar, not a second modal: the user already confirmed once, and the
  // session is no worse off than before the tap.
  showAbSnackBar(context, body, duration: const Duration(seconds: 8));
}
