// app/lib/providers/new_session_action.dart
import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../launcher/host_control_client.dart';
import '../models/session_target.dart';
import '../project/project_session.dart';
import '../project/project_session_registry.dart';
import '../services/control_plane_client.dart';
import '../util/device_id.dart';
import '../utils/platform_utils.dart';
import '../widgets/new_session/picker_sources.dart';
import 'account_agents.dart';
import 'agent_catalog.dart';
import 'agent_transport.dart';
import 'analytics.dart';
import 'cached_sessions.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'new_session_picker.dart';
import 'new_session_start.dart';
import 'projects.dart';
import 'provider_retry.dart';
import 'providers.dart';
import 'recent_agents.dart';
import 'sessions.dart';
import 'ui_attention_providers.dart';

/// Thrown when activating a remote project is refused by the retired
/// concurrent-remote-agent cap (`SESSION_LIMIT_EXCEEDED`, surfaced by the host
/// as a `project:start` control-plane error). Current relays never emit it —
/// the paid axis is the per-account worker cap, enforced at device
/// registration — so this only fires against a relay that has not been
/// upgraded. Kept distinct from a generic start failure because a retry alone
/// won't clear it. [message] is the relay's human string.
class SessionLimitExceededException implements Exception {
  final String message;
  const SessionLimitExceededException(this.message);

  /// What the user is shown. The relay's [message] describes a cap that no
  /// longer exists, so every surface renders this instead — one place to
  /// delete when the code itself goes.
  String get userMessage =>
      'This machine is on an older relay that still limits how many remote '
      'projects can run at once. Update it, or close another remote project '
      'and try again.';

  @override
  String toString() => 'SessionLimitExceededException: $message';
}

/// Map a failed `project:start` outcome to the exception the caller throws. The
/// session-limit rejection is a legacy-relay path (see
/// [SessionLimitExceededException]); everything else (NOT_ALLOWED, OPEN_FAILED,
/// timeout → no error) is a generic, transient failure. `lastError` is the
/// control plane's last error after [awaitProjectRunning] returned false.
Never throwProjectStartFailure(
  String projectId,
  String machineUuid,
  ControlPlaneError? lastError,
) {
  // Retired on current relays, retained so an un-upgraded one still produces a
  // typed rejection rather than an opaque StateError.
  if (lastError?.code == 'SESSION_LIMIT_EXCEEDED') {
    throw SessionLimitExceededException(lastError!.message);
  }
  throw StateError('Could not start project $projectId on $machineUuid');
}

class ActiveSessionsBranchSwitchException implements Exception {
  final String targetId;
  final String branch;
  const ActiveSessionsBranchSwitchException({
    required this.targetId,
    required this.branch,
  });

  @override
  String toString() =>
      'ActiveSessionsBranchSwitchException($targetId, $branch)';
}

/// Thrown when the pre-start branch switch refuses because the folder's
/// working tree is dirty (`DIRTY_WORKTREE`) and the caller hasn't already
/// opted into stashing. The composer catches this, offers to stash, and
/// retries with `stashIfDirty: true` — see [startNewSession].
class DirtyWorktreeBranchSwitchException implements Exception {
  final String targetId;
  final String branch;
  const DirtyWorktreeBranchSwitchException({
    required this.targetId,
    required this.branch,
  });

  @override
  String toString() =>
      'DirtyWorktreeBranchSwitchException($targetId, $branch)';
}

/// Start action for the New Session page.
///
/// Activates the picker-selected target project so `selectedRegistrationIdProvider`
/// becomes its id, waits for the per-project [ProjectSession] (transport +
/// services) to construct, then creates a fresh session in it, marks it active
/// and leaves new-session mode so the workspace renders. The `session:start`
/// goes out on the way through and is reconciled after the hand-off — the
/// bridge may only have QUEUED it behind an isolated checkout's setup run, so
/// its reply is no longer worth blocking the navigation on.
///
/// This replaces the old "instant create" path (a pending provider consumed by
/// `_bootstrapSessions`): the New Session page now owns the explicit
/// pick-target → configure → Start flow.
///
/// Per-variant activation mirrors `activateDrawerEntryById` in
/// `drawer_entry_row.dart`: a local target goes through [selectProject]; a
/// remote one resolves its machine (cached recent, else the account inventory)
/// and lets the connection supervisor bring that machine's socket up.
///
/// Throws on activation/create failure; callers surface the error. Every
/// non-throwing bail-out instead records a [NewSessionStartAbortReason], and
/// each stage publishes itself to [newSessionStartProgressProvider] — a start
/// that ends with nothing to show must still be able to say why.
Future<void> startNewSession(
  ProviderContainer ref, {
  bool allowActiveSessions = false,
  bool stashIfDirty = false,
}) async {
  final target = ref.read(selectedTargetProjectProvider);
  if (target == null) return;
  final selection = ref.read(newSessionBranchSelectionProvider);
  final explicitBranch = (selection != null && selection.targetId == target.id)
      ? selection.branch
      : null;
  final isolated = ref.read(newSessionIsolatedProvider);
  final start = ref.read(newSessionStartProgressProvider.notifier);
  bool intentIsCurrent() {
    final currentTarget = ref.read(selectedTargetProjectProvider);
    final currentSelection = ref.read(newSessionBranchSelectionProvider);
    final currentBranch =
        currentSelection != null && currentSelection.targetId == target.id
        ? currentSelection.branch
        : null;
    return currentTarget?.id == target.id &&
        ref.read(newSessionIsolatedProvider) == isolated &&
        currentBranch == explicitBranch &&
        !ref.read(newSessionStartCancelRequestedProvider);
  }

  // A Stop press and a form edit both fail intentIsCurrent; only the reason
  // handed to the composer tells the user which one ended the start.
  NewSessionStartAbortReason bailReason() =>
      ref.read(newSessionStartCancelRequestedProvider)
      ? NewSessionStartAbortReason.cancelled
      : NewSessionStartAbortReason.intentChanged;

  // Latched here rather than read back off newSessionStartAbortProvider: the
  // composer's listener CONSUMES an abort the instant it lands (synchronously,
  // before this function resumes), so the provider cannot tell "nothing was
  // recorded" from "recorded, and already said" — and the `finally` below
  // would answer a Stop that was reported a second time.
  var aborted = false;
  void abort(NewSessionStartAbortReason reason) {
    aborted = true;
    start.abort(reason);
  }

  // This gate is deliberately checked before doing a shared checkout. An old
  // bridge strips unknown fields, so sending worktree intent without this
  // catalog capability would silently create a shared session.
  if (isolated && !ref.read(newSessionIsolationReadyProvider)) {
    abort(NewSessionStartAbortReason.isolationUnavailable);
    return;
  }

  // Never in the demo. The sample project's branch menu is fixture data
  // (`newSessionBranchCatalogProvider`), so picking one of its branches is
  // ordinary demo navigation — but the checkout's local arm is an `ensureHost()`
  // caller and the demo's target IS a `LocalProject`, so it would spawn the real
  // bridge and check a branch out in whatever directory the fixture names.
  // Skipping costs the user nothing: the create step further down answers with
  // the demo's own refusal either way.
  final willCheckoutBranch =
      !isolated && explicitBranch != null && !ref.read(demoModeProvider);

  final name = ref.read(newSessionNameProvider).trim();
  start.begin(
    // The checkout runs first when there is one, so the status line must open
    // on it rather than flashing the activation copy for a frame.
    phase: willCheckoutBranch
        ? NewSessionStartPhase.switchingBranch
        : NewSessionStartPhase.activating,
    targetId: target.id,
    targetName: target.name,
    deviceName: target.isLocal ? '' : _machineLabelFor(ref, target),
    agentLabel: _agentLabelFor(ref),
    isolated: isolated,
    title: _startTitle(ref, name),
    branch: explicitBranch,
  );
  try {
    // 0. If an explicit branch was selected, perform git checkout BEFORE target activation
    if (willCheckoutBranch) {
      try {
        if (target.isLocal) {
          final host = await ref.read(hostControllerProvider).ensureHost();
          final client = HostControlClient(
            port: host.controlPort,
            token: host.token,
          );
          try {
            await client.gitCheckout(
              projectId: target.id,
              projectPath: target.detail,
              branch: explicitBranch,
              allowActiveSessions: allowActiveSessions,
              stashIfDirty: stashIfDirty,
            );
          } finally {
            client.close();
          }
        } else {
          final machineUuid = target.machineUuid ?? baseDeviceUuid(target.id);
          final client = await ref.read(
            controlPlaneClientForProvider(machineUuid).future,
          );
          if (client == null) {
            throw StateError(
              'Machine $machineUuid is offline; cannot switch branch',
            );
          }
          await client.gitCheckout(
            projectId: target.projectId ?? target.id,
            branch: explicitBranch,
            allowActiveSessions: allowActiveSessions,
            stashIfDirty: stashIfDirty,
          );
        }
      } on HostControlException catch (e) {
        if (e.code == 'ACTIVE_SESSIONS') {
          throw ActiveSessionsBranchSwitchException(
            targetId: target.id,
            branch: explicitBranch,
          );
        }
        if (e.code == 'DIRTY_WORKTREE' && !stashIfDirty) {
          throw DirtyWorktreeBranchSwitchException(
            targetId: target.id,
            branch: explicitBranch,
          );
        }
        rethrow;
      } on RpcException catch (e) {
        if (e.code == 'ACTIVE_SESSIONS') {
          throw ActiveSessionsBranchSwitchException(
            targetId: target.id,
            branch: explicitBranch,
          );
        }
        if (e.code == 'DIRTY_WORKTREE' && !stashIfDirty) {
          throw DirtyWorktreeBranchSwitchException(
            targetId: target.id,
            branch: explicitBranch,
          );
        }
        rethrow;
      }

      // The one step of a start that outlives it. Recorded before the next
      // checkpoint can bail, so whatever ends this start says the tree moved.
      start.markBranchSwitched(explicitBranch);

      // Re-verify selected target and branch selection after await
      if (!intentIsCurrent()) {
        abort(bailReason());
        return;
      }
    }

    // 1. Activate the target so `selectedRegistrationIdProvider` points at it.
    start.advance(NewSessionStartPhase.activating);
    final pid = await _activateTargetProject(ref, target);

    if (!intentIsCurrent()) {
      abort(bailReason());
      return;
    }

    // 2. Wait for the per-project ProjectSession (transport + services) to finish
    // constructing before reading any per-project service façade — otherwise the
    // sync `ref.read(sessionsServiceProvider)` below races the async factory.
    start.advance(NewSessionStartPhase.preparing);
    await ref.read(projectSessionProvider(pid).future);
    if (ref.read(selectedRegistrationIdProvider) != pid || !intentIsCurrent()) {
      abort(bailReason());
      return;
    }

    // 3. Create + start the session, then mark it active.
    final svc = ref.read(sessionsServiceProvider);
    final agent = ref.read(newSessionAgentProvider);
    final customCmd = ref.read(newSessionCustomCmdProvider).trim();
    final cliArgs = ref.read(newSessionCliArgsProvider).trim();
    final tool = newSessionAgentToolKey(agent); // null when custom
    // command is only sent for a custom (non-registry) agent
    final command = tool == null && customCmd.isNotEmpty ? customCmd : null;
    // Chat is only valid for agents KNOWN to be chat-capable
    // (agentSupportsChatResolved: the target's advert, then the persisted
    // catalog). Anything else — including an agent nothing has described —
    // launches Terminal regardless of the (disabled) toggle's last-seen value.
    final chatCapable = agentSupportsChatResolved(
      agent,
      wireChatCapable: ref.read(newSessionChatCapableToolsProvider).value,
      descriptor: tool == null ? null : ref.read(agentCatalogProvider)[tool],
    );
    final mode = (tool != null && chatCapable == true)
        ? ref.read(newSessionModeProvider)
        : 'terminal';

    // An agent rejection (`ok:false`) comes back as a null result, but a
    // dropped/late reply completes the pending request with a TimeoutException
    // (a throw, not null). Guard the whole create→start block so that thrown
    // case is handled like the null one — the draft survives and the canvas is
    // retryable — rather than escaping `startNewSession` as an unhandled async
    // error. Progress is still cleared by the outer `finally`.
    try {
      start.advance(NewSessionStartPhase.creating);
      final created = await svc.create(
        name: name.isEmpty ? null : name,
        tool: tool,
        command: command,
        args: cliArgs.isEmpty ? null : cliArgs,
        mode: mode,
        isolation: isolated ? 'worktree' : 'shared',
        baseBranch: isolated ? explicitBranch : null,
      );
      // create failed (e.g. session cap reached); stay on the New Session page
      // so the user can retry. Only CREATE keeps the user here — once the
      // session exists it is theirs, and the place to report anything further
      // about it is the session itself. A refusal carrying a reason — the
      // sample project's included — never reaches here: `SessionsService.create`
      // fails its completer with a `SessionOperationException`, which the
      // composer's own catch renders.
      if (created == null) {
        abort(NewSessionStartAbortReason.createRefused);
        return;
      }
      // NOT intentChanged: create already landed, so a session exists on the
      // bridge that this bail leaves unstarted — saying "nothing was created"
      // here would be a lie the user cannot check.
      if (ref.read(selectedRegistrationIdProvider) != pid) {
        abort(NewSessionStartAbortReason.abandonedAfterCreate);
        return;
      }
      final prompt = ref.read(newSessionPromptProvider).trim();
      start.advance(NewSessionStartPhase.launching);

      // 4. Send the start, then navigate on it rather than on its reply. An
      // isolated session's start is QUEUED behind the checkout's setup run and
      // answered `ok: true` immediately with `setup.pendingStart` set, so the
      // reply cannot say whether the agent is live — every surface reads that
      // off the session entry instead, and waiting here would only hold the
      // canvas over a session the user is already owed.
      //
      // Sent BEFORE leaveNewSession, deliberately: that remounts WorkspaceShell,
      // whose bootstrap immediately re-lists the sessions and auto-starts the
      // one it adopts if the list says it is stopped. Issuing the start first
      // puts it ahead of that list on the same stream, so the bridge answers
      // with the start already accounted for instead of taking a second one
      // that carries no initialPrompt. That ordering is all a SHARED session
      // needs; an isolated one whose start is queued reports `running: false`
      // for the whole setup run, and the bootstrap's own `sessionStartQueued`
      // guard is what stops it starting over the top.
      final starting = svc.start(
        created.id,
        initialPrompt: prompt.isEmpty ? null : prompt,
        raiseRefusal: true,
      );

      // A start survives the user walking away from the canvas, so only steal
      // the focus of someone still standing on it — otherwise the session they
      // navigated to would be yanked away by work they already left behind.
      // Read here rather than after the reply, because this IS the hand-off:
      // TerminalScreen WATCHES activeSessionIdProvider, so setting it is itself
      // the yank, and by the time the reply lands the user has either been
      // moved or deliberately left behind.
      if (ref.read(workbenchSurfaceProvider) == WorkbenchSurface.newSession) {
        ref.read(activeSessionIdProvider.notifier).set(created.id);
        ref
            .read(analyticsServiceProvider)
            ?.track(
              AnalyticsEvents.sessionOpened,
              props: {'surface': isMobilePlatform ? 'mobile' : 'desktop'},
            );
        // Leaving the canvas REMOUNTS WorkspaceShell (AppShell swaps the whole
        // route), and its bootstrap re-derives the active session from the
        // bridge's `lastUsedAt` ranking. Name the session we just started so
        // that bootstrap adopts it instead of re-deriving: `lastUsedAt`
        // measures ACTIVITY, so a keystroke or an agent notification in another
        // session between `session:start` and the list reply outranks this one
        // and steals the focus the user just asked for.
        ref.read(pendingActiveSessionIdProvider.notifier).set(created.id);
        leaveNewSession(ref);
      }

      // 5. Reconcile the reply now that the user is already in the session. A
      // queued start is a SUCCESS — the entry comes back carrying
      // `setup.pendingStart` — so only a bare rejection (an `ok:true` with no
      // session, an older agent's unknown tool) leaves the draft intact for a
      // return to this canvas; a CODED refusal still raises past here.
      final started = await starting;
      if (started == null) {
        abort(NewSessionStartAbortReason.startRefused);
        return;
      }
      // The session IS running, so this is not a refusal — but it belongs to a
      // project the user has since left. Say where it went instead of clearing
      // the draft as if they had landed in it.
      if (ref.read(selectedRegistrationIdProvider) != pid) {
        abort(NewSessionStartAbortReason.startedAfterSwitch);
        return;
      }
      // An accepted start consumes the draft. Navigation itself preserves
      // drafts, so failures and a later return to this canvas remain editable.
      resetNewSessionForm(ref);
    } on TimeoutException {
      // A dropped/late reply is retryable. Typed bridge failures intentionally
      // reach the composer so it can show their safe display message — though
      // a START refusal now arrives after the hand-off, by which point the
      // composer is unmounted and it is the workspace's OperationalErrorToaster
      // that voices it (the service stamps the reason onto SessionsState.error
      // before failing the pending request).
      //
      // The abort is what a CREATE timeout is owed: that one is still on the
      // canvas, it is the longest wait this flow has, and ending it without a
      // word is the silent vanish the whole progress model exists to remove. A
      // start timeout records one too and nobody is left to read it, which is
      // cheaper than deciding the reason from which await threw.
      abort(NewSessionStartAbortReason.replyTimedOut);
    }
  } finally {
    // A Stop press the flow never reached a checkpoint to observe — because a
    // throw unwound past every one of them — still ended this start at the
    // user's request. Record it here or it dies with the progress it lived on,
    // and the composer's catch arms report a failure the user pre-empted.
    if (!aborted && ref.read(newSessionStartCancelRequestedProvider)) {
      abort(NewSessionStartAbortReason.cancelled);
    }
    start.end();
  }
}

/// Machine label for the start status line. Mirrors `_remoteMachineLabel` in
/// `recent_session_row.dart` — hostMachineName → pairing label → inventory
/// machineName → displayName — so the status line and the Recents row it
/// becomes name the same machine the same way. The recents pass runs first
/// because an offline machine the inventory has not listed still has a row
/// there.
///
/// Ends on the bare uuid rather than a friendlier guess: an unnamed machine is
/// better shown as its id than folded onto another machine's name.
String _machineLabelFor(ProviderContainer ref, PickerProject target) {
  final uuid = target.machineUuid ?? baseDeviceUuid(target.id);
  String? clean(String? s) =>
      (s != null && s.trim().isNotEmpty) ? s.trim() : null;

  if (ref.exists(recentAgentsProvider)) {
    for (final recent in ref.read(recentAgentsProvider)) {
      if (baseDeviceUuid(recent.agentDeviceId) != uuid) continue;
      // The MATCH ends the recents pass, name or no name — the same machine
      // must not be labelled from the recents here and from the inventory in
      // `_remoteMachineLabel`, or the status line and the Recents row it turns
      // into would name it two different ways.
      return clean(recent.hostMachineName) ?? clean(recent.agentLabel) ?? uuid;
    }
  }
  final inventory = ref.exists(accountAgentsProvider)
      ? ref.read(accountAgentsProvider).value
      : null;
  if (inventory != null) {
    for (final agent in inventory) {
      if (agent.deviceUuid != uuid) continue;
      return clean(agent.machineName) ?? agent.displayName;
    }
  }
  return uuid;
}

/// Human agent name for the status line: the target's advertised tool list
/// first, then the persisted catalog, then the bridge's registry key — showing
/// `kilo` is honest, naming it after some other agent is not.
///
/// Every source is read ONLY where something already holds it. Naming a label
/// is not a reason to CREATE one of these: the tool list probes the target (and
/// spawns the local host to do it) and the catalog hydrates off disk, neither
/// of which a start should trigger. The composer keeps both alive for the whole
/// New Session surface, so in practice they answer.
String _agentLabelFor(ProviderContainer ref) => newSessionAgentLabel(
  ref.read(newSessionAgentProvider),
  ref.exists(newSessionDetectedToolsProvider)
      ? ref.read(newSessionDetectedToolsProvider).value
      : null,
  ref.exists(agentCatalogProvider) ? ref.read(agentCatalogProvider) : null,
);

/// What the optimistic Recents row shows where a real session shows its title.
/// The prompt stands in for an unnamed session because that is what the bridge
/// will name it from anyway.
String _startTitle(ProviderContainer ref, String name) {
  if (name.isNotEmpty) return name;
  final prompt = ref.read(newSessionPromptProvider).trim();
  if (prompt.isEmpty) return 'New session';
  return prompt.split('\n').first;
}

/// Test seam over the private [_activateTargetProject]: the production drill-in
/// flow runs through [startNewSession], but that also creates+starts a session
/// (a full [ProjectSession]); this exposes the activation step alone so its
/// target/return-id contract can be asserted in isolation.
@visibleForTesting
Future<String> activateTargetProjectForTest(
  ProviderContainer ref,
  PickerProject target,
) => _activateTargetProject(ref, target);

/// Activate the picker target (local folder / recent remote / inventory remote),
/// mirroring `activateDrawerEntryById`. Returns the id that
/// `selectedRegistrationIdProvider` resolves to (local projectId or remote
/// agentDeviceId), so the caller can await the right [projectSessionProvider].
Future<String> _activateTargetProject(
  ProviderContainer ref,
  PickerProject target,
) async {
  if (target.isLocal) {
    // Local folder project: bump lastOpenedAt + persist + select, exactly as
    // the LocalProjectEntry branch in drawer_entry_row does.
    final project = ref
        .read(projectsProvider)
        .where((p) => p.projectId == target.id)
        .firstOrNull;
    if (project != null) {
      project.lastOpenedAt = DateTime.now();
      await ref.read(projectsProvider.notifier).upsert(project);
    }
    selectProject(ref, target.id);
    return target.id;
  }

  // Remote target: machineUuid + projectId are populated (Tasks 1–3).
  //
  // The phase is published from a callback THIS caller supplies rather than by
  // the activation helper itself: that helper is shared with the drawer's
  // remote-row tap, navigation stays unlocked during a start, and a write from
  // there would let an unrelated tap fast-forward this start's phase (`advance`
  // refuses rewinds, not foreign forward jumps). Only this caller is a New
  // Session start.
  //
  // It fires where `connecting` actually begins — after `project:start` is on
  // the wire — because everything before it (resolving the machine, opening its
  // control-plane socket, the promote itself) is `activating`, and publishing
  // `connecting` up here instead superseded `activating` in the same
  // synchronous turn: no frame ever painted it, so "Waking <machine>…" was
  // copy the user could not see.
  return openRemoteProjectForActivation(
    ref,
    machineUuid: target.machineUuid!,
    projectId: target.projectId!,
    onAwaitingRunning: () => ref
        .read(newSessionStartProgressProvider.notifier)
        .advance(NewSessionStartPhase.connecting),
  );
}

/// Opens a remote advertised project for ACTIVATION (focus): pairs the machine,
/// ALWAYS sends `project:start` (the promote trigger; idempotent for an
/// already-dialable core), and sets [selectedTargetProvider] to the per-project
/// [RemoteProject]. Returns the compound `<uuid>.<projectId>` registrationId the
/// caller awaits as the focus id. We never branch on the advert before sending —
/// the host gates the advert's `running` on a real relay register, so a stale
/// read can't cause us to skip a needed promote.
///
/// Shared by the New Session start flow ([_activateTargetProject]) and the
/// drawer's remote session-row tap, so both reach a live project the same way —
/// a session tap on a cold (advertised-but-not-warm) project would otherwise
/// silently no-op (see `drawer_entry_row.dart`).
///
/// Pairing is MACHINE-level: resolve the recent/inventory by the bare machine
/// uuid, but the SELECTED target + returned id are the per-project compound. The
/// transport for regId opens its own project socket; the machine keypair
/// (baseDeviceUuid(regId) == machineUuid) signs its handshake.
/// [onAwaitingRunning] fires once `project:start` has been accepted and the
/// only thing left is the host's advert — the boundary a caller narrating this
/// wait needs, and null for callers that narrate nothing.
Future<String> openRemoteProjectForActivation(
  ProviderContainer ref, {
  required String machineUuid,
  required String projectId,
  void Function()? onAwaitingRunning,
}) async {
  final regId = RemoteProject(
    machineUuid: machineUuid,
    projectId: projectId,
  ).registrationId; // "<uuid>.<projId>"

  // No pairing step: the control-plane read below is what declares the machine
  // socket wanted, and the supervisor owns the dial + E2E handshake from there.
  // Await the inventory when we hold no cached coordinates, so a still-loading
  // inventory isn't mistaken for "machine unknown".
  final recent = ref
      .read(recentAgentsProvider)
      .where((r) => baseDeviceUuid(r.agentDeviceId) == machineUuid)
      .firstOrNull;
  if (recent == null) {
    final inventory = await ref.read(accountAgentsProvider.future);
    if (!inventory.any((a) => a.deviceUuid == machineUuid)) {
      throw StateError('Selected remote machine $machineUuid is unavailable');
    }
  }

  // ALWAYS send project:start before dialing the data plane — never gate on the
  // advert. The host advertises `running:true` ONLY for a relay-ADMITTED slot
  // (ProjectCore.isRelayRegistered), so a desktop-open-but-unpromoted project
  // reads running:false and a stopped one does too; either way dialing it without
  // a slot would loop AGENT_OFFLINE forever. project:start is the promote trigger
  // and is idempotent for an already-dialable core. awaitProjectRunning then
  // returns immediately ONLY when the advert truthfully reads running (i.e. the
  // slot is admitted); for a not-yet-dialable core it waits for the host's
  // post-register advert (or, on a legacy relay, the retired
  // SESSION_LIMIT_EXCEEDED control:result).
  //
  // Keep-alive dependency: the caller must still be holding machine:M's socket
  // open (the picker via its viewed source; the drawer via the expanded
  // machine/project row) — controlPlaneAliveTargetsProvider keeps it alive, and
  // the reaper would otherwise drop it mid-start (awaitProjectRunning can take
  // up to 30s).
  final cpClient = await ref.read(
    controlPlaneClientForProvider(machineUuid).future,
  );
  if (cpClient == null) {
    throw StateError('Machine $machineUuid is offline; cannot start project');
  }
  try {
    await cpClient.startProject(projectId);
  } on RpcException {
    // The send couldn't be delivered (keyless reconnect window) — fail fast via
    // the standard start-failure surface instead of letting awaitProjectRunning
    // burn the full 30s. lastError won't be a session-limit code here, so this
    // maps to the generic transient "couldn't start" the user can retry.
    throwProjectStartFailure(
      projectId,
      machineUuid,
      cpClient.currentState.lastError,
    );
  }
  onAwaitingRunning?.call();
  final ok = await awaitProjectRunning(cpClient, projectId);
  if (!ok) {
    // Distinguish a legacy relay's retired session cap from a generic transient
    // start failure: an old host still pushes SESSION_LIMIT_EXCEEDED as the
    // project:start control-plane error when it rejects the slot.
    throwProjectStartFailure(
      projectId,
      machineUuid,
      cpClient.currentState.lastError,
    );
  }

  ref
      .read(selectedTargetProvider.notifier)
      .set(RemoteProject(machineUuid: machineUuid, projectId: projectId));
  return regId;
}

/// Lazily prepares a remote project for the DRAWER's per-project expand and
/// fetches its session list ONCE — WITHOUT changing the focused project (the
/// drawer is a passive peek, not an activation) and WITHOUT starting the
/// project. Pairs the machine so the control-plane socket is live, then reads
/// the persisted session list over the control plane (`sessions.list`) and
/// writes it through to `cachedSessionsProvider`, which `sessionsForEntryProvider`
/// renders.
///
/// The data plane (and `project:start`/promotion) is reserved for focus/
/// activation — expanding a row never warms a core or runs a stopped project's
/// startup terminals. `running` flags read false here (disk carries no runtime
/// state); the live list is fetched on focus.
///
/// `autoDispose` so each expand re-pulls fresh and the in-flight fetch drops on
/// collapse. Keyed by `regId` ALONE.
final drawerProjectSessionsProvider = FutureProvider.autoDispose.family<void, String>((
  ref,
  regId,
) async {
  final machineUuid = baseDeviceUuid(regId);
  // Needs a compound `<machineUuid>.<projectId>` id. baseDeviceUuid returns the
  // input unchanged when there is no dot, so a bare id would make the substring
  // below throw RangeError — fail with a clear message instead.
  if (machineUuid == regId) {
    throw StateError(
      'drawer session peek needs a <machineUuid>.<projectId> id, got "$regId"',
    );
  }
  final projectId = regId.substring(machineUuid.length + 1);

  // 1. The machine must be one we can reach. The control-plane read in step 2
  // declares its socket wanted (the supervisor dials and handshakes); all this
  // needs to do is fail early on a machine we hold no coordinates for, without
  // mistaking a still-loading inventory for an empty one.
  final recent = ref
      .read(recentAgentsProvider)
      .where((r) => baseDeviceUuid(r.agentDeviceId) == machineUuid)
      .firstOrNull;
  if (recent == null) {
    final inventory = await ref.read(accountAgentsProvider.future);
    if (!inventory.any((a) => a.deviceUuid == machineUuid)) {
      throw StateError('Remote machine $machineUuid is unavailable');
    }
  }

  // 2. Fetch the session list over the CONTROL PLANE — no data-plane socket, no
  // project:start. An RpcException (NOT_ALLOWED / timeout) surfaces as the
  // provider's error state, which the drawer renders as a tap-to-retry hint.
  final cp = await ref.read(controlPlaneClientForProvider(machineUuid).future);
  if (cp == null) {
    throw StateError('Machine $machineUuid is offline');
  }
  final sessions = await cp.listSessions(projectId);

  // 3. Write through to the cache the drawer renders from
  // (sessionsForEntryProvider(regId) → cachedSessionsProvider(regId)).
  await ref.read(cachedSessionsStoreProvider).put(regId, sessions);
}, retry: noProviderRetry);

/// Waits until [client] reports [projectId] as running, or fails.
/// Returns true on running; false on a control-plane error or [timeout].
/// Does NOT throw — the caller stays on the picker on any false.
Future<bool> awaitProjectRunning(
  ControlPlaneClient client,
  String projectId, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  bool isRunning(ControlPlaneState s) =>
      s.projects.any((p) => p.projectId == projectId && p.running);
  if (isRunning(client.currentState)) return true;

  final errorAtStart = client.currentState.lastError;
  final completer = Completer<bool>();
  late final StreamSubscription sub;
  sub = client.stateStream.listen((s) {
    if (isRunning(s)) {
      if (!completer.isCompleted) completer.complete(true);
    } else if (!identical(s.lastError, errorAtStart) && s.lastError != null) {
      // A control-plane error arrived after we sent (NOT_ALLOWED / UNKNOWN_PROJECT
      // / OPEN_FAILED). There is no per-verb correlation id, but we only ever have
      // one start in flight, so any fresh error is ours.
      if (!completer.isCompleted) completer.complete(false);
    }
  });
  try {
    return await completer.future.timeout(timeout, onTimeout: () => false);
  } finally {
    await sub.cancel();
  }
}
