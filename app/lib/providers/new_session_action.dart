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
import 'new_session_picker.dart';
import 'projects.dart';
import 'provider_retry.dart';
import 'providers.dart';
import 'recent_agents.dart';
import 'sessions.dart';

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

/// Start action for the New Session page.
///
/// Activates the picker-selected target project so `selectedRegistrationIdProvider`
/// becomes its id, waits for the per-project [ProjectSession] (transport +
/// services) to construct, then creates and starts a fresh session in it and
/// marks it active. Finally leaves new-session mode so the workspace renders.
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
/// Throws on activation/create failure; callers surface the error.
Future<void> startNewSession(
  ProviderContainer ref, {
  bool allowActiveSessions = false,
}) async {
  final target = ref.read(selectedTargetProjectProvider);
  if (target == null) return;
  final selection = ref.read(newSessionBranchSelectionProvider);
  final explicitBranch = (selection != null && selection.targetId == target.id)
      ? selection.branch
      : null;
  final isolated = ref.read(newSessionIsolatedProvider);
  bool intentIsCurrent() {
    final currentTarget = ref.read(selectedTargetProjectProvider);
    final currentSelection = ref.read(newSessionBranchSelectionProvider);
    final currentBranch =
        currentSelection != null && currentSelection.targetId == target.id
        ? currentSelection.branch
        : null;
    return currentTarget?.id == target.id &&
        ref.read(newSessionIsolatedProvider) == isolated &&
        currentBranch == explicitBranch;
  }

  // This gate is deliberately checked before doing a shared checkout. An old
  // bridge strips unknown fields, so sending worktree intent without this
  // catalog capability would silently create a shared session.
  if (isolated && !ref.read(newSessionIsolationReadyProvider)) return;

  ref.read(newSessionStartInFlightProvider.notifier).set(true);
  try {
    // 0. If an explicit branch was selected, perform git checkout BEFORE target activation
    if (!isolated && explicitBranch != null) {
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
          );
        }
      } on HostControlException catch (e) {
        if (e.code == 'ACTIVE_SESSIONS') {
          throw ActiveSessionsBranchSwitchException(
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
        rethrow;
      }

      // Re-verify selected target and branch selection after await
      if (!intentIsCurrent()) return;
    }

    final name = ref.read(newSessionNameProvider).trim();

    // 1. Activate the target so `selectedRegistrationIdProvider` points at it.
    final pid = await _activateTargetProject(ref, target);

    if (!intentIsCurrent()) return;

    // 2. Wait for the per-project ProjectSession (transport + services) to finish
    // constructing before reading any per-project service façade — otherwise the
    // sync `ref.read(sessionsServiceProvider)` below races the async factory.
    await ref.read(projectSessionProvider(pid).future);
    if (ref.read(selectedRegistrationIdProvider) != pid || !intentIsCurrent()) {
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
    // case is handled like the null one — stay on the New Session page — rather
    // than escaping `startNewSession` as an unhandled async error. The
    // in-flight flag is still cleared by the outer `finally`.
    try {
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
      // so the user can retry.
      if (created == null) return;
      if (ref.read(selectedRegistrationIdProvider) != pid) return;
      final prompt = ref.read(newSessionPromptProvider).trim();
      final started = await svc.start(
        created.id,
        initialPrompt: prompt.isEmpty ? null : prompt,
        raiseRefusal: true,
      );
      // start failed with no reason on the wire (an `ok:true` carrying no
      // session, or an older agent's bare rejection — an unknown tool, no agent
      // configured); a CODED refusal is raised past here to the composer, which
      // says what it was. Either way stay on the New Session page so the user
      // can retry rather than dropping into a session whose PTY never spawned.
      if (started == null) return;
      if (ref.read(selectedRegistrationIdProvider) != pid) return;
      ref.read(activeSessionIdProvider.notifier).set(created.id);
      ref
          .read(analyticsServiceProvider)
          ?.track(
            AnalyticsEvents.sessionOpened,
            props: {'surface': isMobilePlatform ? 'mobile' : 'desktop'},
          );

      // 4. A successful start consumes the draft. Navigation itself preserves
      // drafts, so failures and a later return to this canvas remain editable.
      resetNewSessionForm(ref);
      // Leaving the canvas REMOUNTS WorkspaceShell (AppShell swaps the whole
      // route), and its bootstrap re-derives the active session from the
      // bridge's `lastUsedAt` ranking. Name the session we just started so that
      // bootstrap adopts it instead of re-deriving: `lastUsedAt` measures
      // ACTIVITY, so a keystroke or an agent notification in another session
      // between `session:start` and the list reply outranks this one and steals
      // the focus the user just asked for.
      ref.read(pendingActiveSessionIdProvider.notifier).set(created.id);
      leaveNewSession(ref);
    } on TimeoutException {
      // A dropped/late reply is retryable. Typed bridge failures intentionally
      // reach the composer so it can show their safe display message.
    }
  } finally {
    ref.read(newSessionStartInFlightProvider.notifier).set(false);
  }
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
  return openRemoteProjectForActivation(
    ref,
    machineUuid: target.machineUuid!,
    projectId: target.projectId!,
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
Future<String> openRemoteProjectForActivation(
  ProviderContainer ref, {
  required String machineUuid,
  required String projectId,
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
