import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../models/agent_work_status.dart';
import '../models/session_entry.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/focused_tools.dart';
import '../providers/new_session_picker.dart';
import '../providers/session_mode.dart';
import '../providers/sessions.dart';
import '../services/sessions_service.dart';
import 'mode_segmented.dart';

/// Switches the focused session between terminal and chat.
///
/// The two ways this can be unavailable are answered differently on purpose.
/// A conversation that can no longer be resumed
/// ([SessionEntry.agentSessionResumable]) hides the whole control — it is
/// transient, per-session, and there is no honest short copy for "the
/// conversation this would carry over is gone". An agent with no chat driver is
/// permanent and knowable, so the control stays visible with the Chat cell
/// greyed and its reason reachable.
///
/// Mounted in BOTH the mobile agent-panel header and the desktop window title
/// bar (which replaced that header) — either one alone ships the feature to
/// half the platforms.
class SessionModeControl extends ConsumerWidget {
  const SessionModeControl({super.key, this.showIcons = true});

  /// Icons are garnish; the phone header drops them for room.
  final bool showIcons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeSessionProvider);
    if (active == null || !active.agentSessionResumable) {
      return const SizedBox.shrink();
    }
    final pending = ref.watch(pendingSessionModeProvider);
    final inFlight = pending?.sessionId == active.id;

    return ModeSegmented(
      keyPrefix: 'session-mode',
      mode: ref.watch(activeSessionModeProvider) ?? active.mode,
      chatEnabled: ref.watch(focusedToolChatCapableProvider(active.tool)),
      // Shorter than the create-time picker's "<Agent> doesn't support chat
      // sessions": mid-session the agent is established context, and the
      // string renders inches from a greyed Chat cell.
      chatDisabledReason: 'Not supported',
      enabled: !inFlight,
      showIcons: showIcons,
      onChanged: (next) => _switchMode(context, ref, active, next),
    );
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
      AgentWorkStatus.done || AgentWorkStatus.error || null => null,
    };

Future<void> _switchMode(
  BuildContext context,
  WidgetRef ref,
  SessionEntry session,
  String target,
) async {
  // Captured before the dialog: the focused project can re-resolve while it is
  // open, and a WidgetRef read past that point throws. Everything downstream
  // goes through the container so an unmount mid-flip still clears `pending`.
  final container = ref.container;
  final agent =
      container.read(focusedMachineToolsProvider).value?.labels[session.tool] ??
      sessionAgentDisplayLabel(session);

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
      : container.read(projectSessionProvider(projectId)).value?.sessionsService;
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
