// app/lib/widgets/drawer_entry_row.dart
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/supervisor_state.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/drawer_entry.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../util/device_id.dart';
import '../project/limits.dart';
import '../project/perf_recorder.dart';
import '../project/project_session_registry.dart';
import '../project/project_status.dart';
import '../providers/agent_transport.dart';
import '../providers/cached_sessions.dart';
import '../providers/drawer_entries.dart';
import '../providers/collapsed_drawer.dart';
import '../providers/drawer_expansion.dart';
import '../providers/new_session_action.dart'
    show SessionLimitExceededException, openRemoteProjectForActivation;
import '../providers/new_session_picker.dart'
    show
        enterNewSession,
        selectedSourceIdProvider,
        selectedTargetProjectProvider;
import '../providers/project_work_status.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/recent_agents.dart';
import '../providers/supervisor_status.dart';
import '../screens/upgrade_screen.dart';
import '../services/control_plane_client.dart';
import 'ab_status_helpers.dart';
import 'agent_work_status_dot.dart';
import 'session_isolation_badge.dart' show sessionIsIsolated;

/// One row in the projects drawer.
class DrawerEntryRow extends ConsumerStatefulWidget {
  final DrawerEntry entry;
  const DrawerEntryRow(this.entry, {super.key});

  @override
  ConsumerState<DrawerEntryRow> createState() => _DrawerEntryRowState();
}

/// Lightweight group-header variant for a remote machine row in the drawer.
/// Stateless: the only per-row UI state is hover, owned by [_HoverableDrawerRow].
class MachineDrawerHeaderRow extends ConsumerWidget {
  final DrawerEntry entry;
  const MachineDrawerHeaderRow(this.entry, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    perfRecorder.noteDrawerRebuild();
    final machineUuid = entry.machineUuid!;
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(machineUuid);
    final t = context.antgrid;

    return _HoverableDrawerRow(
      builder: (context, hovered) => AbListRow(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MachineOnlineDot(machineUuid: machineUuid),
            _MachineAggregateDot(machineUuid: machineUuid),
            Flexible(
              child: Text(
                entry.displayName,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: t.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: AbTokens.space4),
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 120),
              child: AbIcon(AbIcons.chevronRight, size: 10, color: t.textMuted),
            ),
          ],
        ),
        trailing: _DrawerEntryTrailing(entry: entry, hovered: hovered),
        density: AbRowDensity.sm,
        horizontalPadding: 0,
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        hoverable: true,
        onTap: () =>
            ref.read(expandedDrawerIdsProvider.notifier).toggle(machineUuid),
      ),
    );
  }
}

/// Shared hover shell for drawer rows: the gutter [Padding] kept outside the
/// [MouseRegion] (so the L/R strips aren't hover/tap-reactive), the click cursor,
/// and the `_hovered` bit both row variants drive. Mobile has no hover, so
/// affordances start visible. [onHoverStart]/[onHoverEnd] let a row hang extra
/// work (e.g. a prefetch timer) off the desktop pointer transitions; they never
/// fire on mobile.
class _HoverableDrawerRow extends StatefulWidget {
  const _HoverableDrawerRow({
    required this.builder,
    this.onHoverStart,
    this.onHoverEnd,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onHoverStart;
  final VoidCallback? onHoverEnd;

  @override
  State<_HoverableDrawerRow> createState() => _HoverableDrawerRowState();
}

class _HoverableDrawerRowState extends State<_HoverableDrawerRow> {
  late bool _hovered = isMobilePlatform;

  void _onEnter(PointerEnterEvent _) {
    if (isMobilePlatform) return;
    if (!_hovered && mounted) setState(() => _hovered = true);
    widget.onHoverStart?.call();
  }

  void _onExit(PointerExitEvent _) {
    if (isMobilePlatform) return;
    if (_hovered && mounted) setState(() => _hovered = false);
    widget.onHoverEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.drawerGutter),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: _onEnter,
        onExit: _onExit,
        child: widget.builder(context, _hovered),
      ),
    );
  }
}

class _DrawerEntryRowState extends ConsumerState<DrawerEntryRow> {
  Timer? _prefetchTimer;

  void _startPrefetch() {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(kHoverPrefetchDelay, () {
      // ignore: unused_result
      ref.read(projectSessionProvider(widget.entry.id).future);
    });
  }

  void _cancelPrefetch() {
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    perfRecorder.noteDrawerRebuild();
    final entry = widget.entry;
    // Remote MACHINE rows default to COLLAPSED
    final machineUuid = entry.machineUuid;
    final expanded = machineUuid != null
        ? ref.watch(expandedDrawerIdsProvider).contains(machineUuid)
        : !ref.watch(collapsedDrawerIdsProvider).contains(entry.id);
    final isWarm = ref.watch(
      projectSessionRegistryProvider.select((open) => open.contains(entry.id)),
    );

    return _HoverableDrawerRow(
      onHoverStart: _startPrefetch,
      onHoverEnd: _cancelPrefetch,
      builder: (context, hovered) => AbListRow(
        // Folder by default; chevron on hover. Both sit in the same pinned slot
        // so the glyph swap doesn't shift the title.
        leading: Opacity(
          opacity: isWarm ? 1.0 : 0.6,
          child: hovered
              ? AbDisclosureChevron(expanded: expanded)
              : SizedBox(
                  width: AbTokens.drawerLeadingSlot,
                  height: AbTokens.drawerLeadingSlot,
                  child: Center(
                    child: AbIcon(
                      AbIcons.folder,
                      // Match chevron size so the glyph doesn't shrink on hover.
                      size: 10,
                      color: context.antgrid.textMuted,
                    ),
                  ),
                ),
        ),
        title: Text(
          entry.displayName,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: context.antgrid.textSecondary,
          ),
        ),
        trailing: _DrawerEntryTrailing(entry: entry, hovered: hovered),
        density: AbRowDensity.sm,
        horizontalPadding: 0, // gutter lives on the outer Padding
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        onTap: () => machineUuid != null
            ? ref.read(expandedDrawerIdsProvider.notifier).toggle(machineUuid)
            : ref.read(collapsedDrawerIdsProvider.notifier).toggle(entry.id),
      ),
    );
  }
}

/// Right-hand affordances of a drawer row: config error, running command,
/// REMOTE chip, and the hover actions.
///
/// Deliberately carries NO work-status dot. Work status belongs to the SESSION
/// rows nested under the row, and a project-level rollup beside them only
/// restated whichever session was loudest. A collapsed machine HEADER still
/// shows its aggregate dot ([_MachineAggregateDot]) — it has no session rows on
/// screen to carry one.
class _DrawerEntryTrailing extends ConsumerWidget {
  const _DrawerEntryTrailing({required this.entry, required this.hovered});

  final DrawerEntry entry;
  final bool hovered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(projectStatusProvider(entry.id));
    final status = statusAsync.value ?? const ProjectStatus.empty();

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AbTokens.space4,
      children: [
        if (status.configError)
          _ErrorDot(
            key: ValueKey('drawer-error-dot-${entry.id}'),
            message: status.configErrorMessage,
          ),
        if (status.activeCommandName != null)
          _CommandIndicator(
            key: ValueKey('drawer-cmd-indicator-${entry.id}'),
            commandName: status.activeCommandName!,
          ),
        if (entry.kind == EntryKind.remote)
          AbChip.system(label: 'REMOTE', color: context.antgrid.accent),
        // Hover-only affordances; kept in the tree via Visibility so layout
        // doesn't jitter on pointer-enter. Remove is always offered (any
        // project can be dropped from history, with a confirm) — `_RemoveButton`
        // hides itself only for inventory agents, which have no locally-stored
        // state to remove.
        Visibility(
          visible: hovered,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AbTokens.space4,
            children: [
              // No per-machine "New session" +: a machine is a container, not a
              // project, so a session must name a project. The + lives on each
              // advertised project row instead (see `_AdvertisedProjectRow`).
              if (entry.machineUuid == null) _NewSessionButton(entry: entry),
              _RemoveButton(entry: entry),
            ],
          ),
        ),
      ],
    );
  }
}

/// Trash affordance for removing a project/agent from history. Any project
/// can be removed (active sessions or not) — removing the selected project
/// clears the selection (`ProjectsNotifier.remove`) and the remote branch
/// unpairs first, so it's safe regardless of session state.
class _RemoveButton extends ConsumerStatefulWidget {
  final DrawerEntry entry;
  const _RemoveButton({required this.entry});

  @override
  ConsumerState<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends ConsumerState<_RemoveButton> {
  // Self-disable while a confirmed removal's async teardown is in flight so a
  // second tap can't re-enter `_confirmRemove` (matching `_NewSessionButton`).
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    // Inventory agents have no locally-stored state to remove — hide the
    // trash affordance entirely (they're managed server-side).
    if (entry is InventoryAgentEntry) return const SizedBox.shrink();
    final isLocal = entry is LocalProjectEntry;
    return AbIconButton(
      icon: AbIcons.trash,
      tooltip: isLocal ? 'Remove from history' : 'Forget agent',
      onTap: _busy ? null : () => _confirmRemove(isLocal: isLocal),
    );
  }

  Future<void> _confirmRemove({required bool isLocal}) async {
    final entry = widget.entry;
    // Captured before the dialog await: the removal below must still run if the
    // drawer rebuilt this row away while the confirm was open.
    final container = ref.container;
    final ok = await AbConfirmDialog.show(
      context: context,
      title: isLocal
          ? 'Remove ${entry.displayName}?'
          : 'Forget ${entry.displayName}?',
      body: isLocal
          ? removeLocalProjectBody(container, entry.id)
          : 'This removes the saved trust relationship. You\'ll need to scan the QR code again to reconnect.',
      confirmLabel: isLocal ? 'Remove' : 'Forget',
      destructive: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      switch (entry) {
        case LocalProjectEntry e:
          // `ProjectsNotifier.remove` owns the local teardown: it stops the
          // project's sessions/terminals, disposes its services + transport,
          // then forgets the record.
          await container.read(projectsProvider.notifier).remove(e.id);
        case RemoteAgentEntry e:
          await container
              .read(pairedAgentProvider.notifier)
              .forgetMachine(e.agent.agentDeviceId);
        case InventoryAgentEntry _:
          // Inventory agents are not stored locally — nothing to remove.
          // The entry will disappear from the list when the account inventory
          // is next refreshed or the device is deleted server-side.
          break;
      }
    } finally {
      // The row is usually gone after removal (entry dropped from the drawer);
      // guard the setState so we don't touch a disposed State.
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// What removing a local project actually costs, stated for this project.
///
/// The first sentence is unconditional and deliberately narrower than it used to
/// be: removing a project makes the bridge forget it, and forgetting reclaims
/// every managed checkout the project owns — so "the folder is not deleted" is
/// true of the project folder and false of the isolated workspaces beneath the
/// state directory. Naming only the folder keeps the reassurance the user
/// actually needs (their repository is untouched) without extending it to
/// directories this action does delete.
///
/// The isolation sentence is added from the SESSION CACHE, which knows only what
/// this app has seen. That is why it names the consequence without counting
/// sessions: a cold project reports nothing cached, and a promise about "your 2
/// isolated sessions" would be wrong the moment the cache is stale or partial.
/// The unconditional half has to stand on its own for exactly that case.
String removeLocalProjectBody(ProviderContainer container, String projectId) {
  const shared =
      'This stops any running sessions and removes it from your project '
      'history. The project folder is not deleted.';
  final hasIsolated = container
      .read(cachedSessionsProvider(projectId))
      .any(sessionIsIsolated);
  if (!hasIsolated) return shared;
  return '$shared Its isolated sessions lose their separate working '
      'directories, including any uncommitted changes in them. Their branches '
      'are kept.';
}

/// Top-level helper so the kebab and inline connect actions can share one
/// implementation. Returns `true` when the remote is now active, `false` if
/// the attempt failed (snackbar already shown). Callers may use the signal
/// to restore the previous selection.
Future<bool> selectRemoteAgent(
  BuildContext context,
  ProviderContainer ref,
  String agentDeviceId,
) async {
  try {
    final paired = ref.read(pairedAgentProvider).value ?? const [];
    final isPaired = paired.any((a) => a.agentDeviceId == agentDeviceId);
    if (isPaired) {
      await ref.read(pairedAgentProvider.notifier).selectAgent(agentDeviceId);
      return true;
    }
    final ra = ref
        .read(recentAgentsProvider)
        .firstWhere((r) => r.agentDeviceId == agentDeviceId);
    // No rendezvous: reading the machine's transport declares the connection
    // wanted and hands the supervisor the ladder (dial → presence → E2E
    // handshake as this app's own DeviceRecord). It throws with the block
    // reason when the supervisor gives up, which is what the snackbar reports.
    await ref.read(agentTransportForProvider(ra.agentDeviceId).future);
    ref
        .read(selectedTargetProvider.notifier)
        .set(RemoteTarget.legacy(ra.agentDeviceId));
    return true;
  } catch (e) {
    if (context.mounted) {
      showAbSnackBar(context, 'Connect failed: $e');
    }
    return false;
  }
}

/// Reconnects the live remote agent if its transport is currently offline.
/// No-op for local projects (their transport is managed by
/// `agentTransportProvider`). Skips on `connecting` so we don't race an
/// in-flight connect.
Future<bool> ensureRemoteOnline(
  BuildContext context,
  ProviderContainer ref,
  String agentDeviceId,
) async {
  if (ref.read(agentReachabilityProvider) != AgentReachability.offline) {
    return true;
  }
  return selectRemoteAgent(context, ref, agentDeviceId);
}

/// Public activation entry point for drawer interactions (session-row click,
/// inactive `+ New session` tap). The row's own tap is now a pure expand /
/// collapse toggle — this is the sole activation path for projects from
/// drawer interactions. Resolves the entry by id; for local entries it
/// updates `lastOpenedAt` + persists + calls `selectProject`; for
/// remote entries it calls [selectRemoteAgent] and restores the prior local
/// selection on failure.
///
/// Takes the [ProviderContainer], never a caller's `WidgetRef`: activation is
/// the thing that tears the caller down (the switch rebuilds the drawer, and
/// pops it on mobile), yet the target save/restore below must still land — and
/// a cold remote open can run for ~30s before it does. `context` stays a widget
/// context, but only ever behind a `context.mounted` guard for UI.
Future<bool> activateDrawerEntryById(
  BuildContext context,
  ProviderContainer ref,
  String entryId,
) async {
  final entries = ref.read(drawerEntriesProvider);
  final entry = entries.where((e) => e.id == entryId).firstOrNull;
  if (entry == null) {
    // A session row nested under a remote MACHINE entry carries its project's
    // compound `<uuid>.<projectId>` regId, which is not itself a drawer entry
    // (the entry is the bare-uuid machine). When that project is already open
    // (warm transport), refocus it as a remote target — no re-pair needed.
    if (_focusOpenRemoteProject(ref, entryId)) return true;
    // A cold (advertised-but-not-warm) project still needs pairing, promotion,
    // and a data-plane socket before it can be focused — `_focusOpenRemoteProject`
    // only refocuses one that is already warm.
    return _openColdRemoteProject(context, ref, entryId);
  }

  // Drop duplicate taps while a remote connection is mid-flight to prevent
  // overlapping selectAgent() calls. Gated on `focusedIsRelayProvider`
  // because `agentReachabilityProvider` returns `connecting` by default
  // whenever no agent is active (including pure local mode), which would
  // otherwise block every tap. Gated on `focusedAgentBlockedProvider` because
  // a blocked ladder also reads `connecting` and never leaves it on its own:
  // without this the tap is a silent no-op forever and the user can never
  // reach the error surface that holds Retry.
  if (entry is RemoteAgentEntry || entry is InventoryAgentEntry) {
    final hasActiveRemote = ref.read(focusedIsRelayProvider);
    if (hasActiveRemote &&
        !ref.read(focusedAgentBlockedProvider) &&
        ref.read(agentReachabilityProvider) == AgentReachability.connecting) {
      return false;
    }
  }

  bool ok;
  switch (entry) {
    case LocalProjectEntry e:
      e.project.lastOpenedAt = DateTime.now();
      await ref.read(projectsProvider.notifier).upsert(e.project);
      selectProject(ref, e.id);
      ok = true;
      break;
    case RemoteAgentEntry e:
      final priorTarget = ref.read(selectedTargetProvider);
      ref.read(selectedTargetProvider.notifier).set(null);
      ok = await selectRemoteAgent(context, ref, e.agent.agentDeviceId);
      if (!ok) {
        ref.read(selectedTargetProvider.notifier).set(priorTarget);
      }
      break;
    case InventoryAgentEntry e:
      // Same-account machine straight from the peers inventory — no QR, no
      // pairing. Reading its transport brings the supervisor up; the agent
      // admits us from the inventory when the E2E handshake lands.
      final priorTarget = ref.read(selectedTargetProvider);
      ref.read(selectedTargetProvider.notifier).set(null);
      try {
        await ref.read(agentTransportForProvider(e.agent.deviceUuid).future);
        ref
            .read(selectedTargetProvider.notifier)
            .set(RemoteTarget.legacy(e.agent.deviceUuid));
        ok = true;
      } catch (ex) {
        ref.read(selectedTargetProvider.notifier).set(priorTarget);
        if (context.mounted) {
          showAbSnackBar(context, 'Connect failed: $ex');
        }
        ok = false;
      }
  }

  // Record a workspace entry for a plain remote-entry tap. recordProjectFocus
  // owns the pending-session guard (a cross-project session tap commits the
  // resolved target+session via session_row instead). Local entries route
  // through selectProject, which records its own entry.
  if (ok && (entry is RemoteAgentEntry || entry is InventoryAgentEntry)) {
    recordProjectFocus(ref);
  }

  // Mobile UX: close the drawer after a successful activation so the user
  // sees the new workspace instead of the still-open drawer.
  if (ok && context.mounted) {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.hasDrawer == true && scaffold!.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }
  return ok;
}

/// Refocus an already-open remote project by its compound `<uuid>.<projectId>`
/// regId. Returns false (caller treats as a no-op) when the id isn't a compound
/// id or the project isn't currently warm — this path never opens a cold
/// project, it only switches focus to one whose transport is already live.
bool _focusOpenRemoteProject(ProviderContainer ref, String regId) {
  if (!regId.contains('.')) return false;
  final isOpen = ref.read(projectSessionRegistryProvider).contains(regId);
  if (!isOpen) return false;
  final machineUuid = baseDeviceUuid(regId);
  final projectId = regId.substring(machineUuid.length + 1);
  ref
      .read(selectedTargetProvider.notifier)
      .set(RemoteProject(machineUuid: machineUuid, projectId: projectId));
  recordProjectFocus(ref);
  return true;
}

/// Opens a cold remote advertised project (its compound `<uuid>.<projectId>`
/// regId) from a drawer session-row tap: pairs the machine, promotes it
/// (unconditionally — `project:start` is the promote trigger and is idempotent;
/// see [openRemoteProjectForActivation]), and focuses it. Restores the prior
/// target and shows a snackbar on failure, mirroring the other remote activation
/// branches.
Future<bool> _openColdRemoteProject(
  BuildContext context,
  ProviderContainer ref,
  String regId,
) async {
  if (!regId.contains('.')) return false;
  final machineUuid = baseDeviceUuid(regId);
  final projectId = baseProjectId(regId);
  final priorTarget = ref.read(selectedTargetProvider);
  ref.read(selectedTargetProvider.notifier).set(null);
  try {
    await openRemoteProjectForActivation(
      ref,
      machineUuid: machineUuid,
      projectId: projectId,
    );
    recordProjectFocus(ref);
    return true;
  } on SessionLimitExceededException catch (e) {
    // A legacy relay's retired cap, not a transient connect failure — retrying
    // won't clear it, so say what will and show the plan the account is on.
    ref.read(selectedTargetProvider.notifier).set(priorTarget);
    if (context.mounted) {
      showAbSnackBar(context, e.userMessage);
      await openUpgrade(context, ref);
    }
    return false;
  } catch (e) {
    ref.read(selectedTargetProvider.notifier).set(priorTarget);
    if (context.mounted) {
      showAbSnackBar(context, 'Connect failed: $e');
    }
    return false;
  }
}

/// Per-row "New session" affordance. Stateful so we can self-disable while a
/// previous tap's create/start (or project switch) is still in flight —
/// double-tapping would otherwise spawn duplicate sessions.
class _NewSessionButton extends ConsumerStatefulWidget {
  final DrawerEntry entry;
  const _NewSessionButton({required this.entry});

  @override
  ConsumerState<_NewSessionButton> createState() => _NewSessionButtonState();
}

class _NewSessionButtonState extends ConsumerState<_NewSessionButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return AbIconButton(
      icon: AbIcons.add,
      tooltip: 'New session',
      onTap: _busy ? null : _onTap,
    );
  }

  Future<void> _onTap() async {
    setState(() => _busy = true);
    try {
      await _newSessionForEntry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newSessionForEntry() async {
    // The container, not `ref`: activating + warming the project outlives this
    // row (the entry is usually gone once the switch lands), and a `WidgetRef`
    // read past that point throws.
    final container = ref.container;
    final entryId = widget.entry.id;
    final machineUuid = widget.entry.machineUuid;
    if (machineUuid != null) {
      // A machine row is a control-plane container, not a project transport.
      // Route to its project picker instead of focusing the bare deviceUuid as
      // a legacy remote project, which would tear down the control plane.
      enterNewSession(container);
      container
          .read(selectedSourceIdProvider.notifier)
          .set('machine:$machineUuid');
      container.read(selectedTargetProjectProvider.notifier).set(null);
      return;
    }
    final liveId = container.read(selectedRegistrationIdProvider);
    final isLive = entryId == liveId;
    try {
      // Activate the entry's project (select local / reconnect remote) unless
      // it's already the live focus, then route to the New Session page with
      // that project preselected so the user picks an agent (no cold-start).
      // Creation itself is owned by `startNewSession` in `new_session_action.dart`.
      if (!isLive) {
        final ok = await activateDrawerEntryById(context, container, entryId);
        if (!ok) return; // activation failed; snackbar already shown
      } else if (widget.entry case RemoteAgentEntry e) {
        if (!await ensureRemoteOnline(
          context,
          container,
          e.agent.agentDeviceId,
        )) {
          return;
        }
      }

      // Activation resolves the focus id (a remote entry's id may differ from
      // the live `agentDeviceId` it reconnects/auto-pairs to), so read it back
      // rather than reusing `entryId`.
      final pid = container.read(selectedRegistrationIdProvider);
      if (pid == null) return;

      // Warm the per-project ProjectSession (transport + services) so the
      // New Session page — and the subsequent startNewSession — find a ready
      // session rather than racing the async factory.
      await container.read(projectSessionProvider(pid).future);
      if (container.read(selectedRegistrationIdProvider) != pid) return;

      // Route to the New Session page with this project preselected (it is the
      // current focus, so enterNewSession reverse-looks-it-up as the target and
      // seeds the agent dropdown from its agent:hello).
      enterNewSession(container);
    } catch (e) {
      if (mounted) {
        showAbSnackBar(context, 'New session failed: $e');
      }
    }
  }
}

/// Online/offline dot for a remote machine header. Peek-only
/// ([supervisorStatusProvider] never dials), so a collapsed-but-healthy
/// machine isn't mislabelled: a null status (never connected → unknown) renders
/// nothing, and the dot appears once the socket is dialed (on expand / refresh).
class _MachineOnlineDot extends ConsumerWidget {
  const _MachineOnlineDot({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(supervisorStatusProvider(machineUuid)).value;
    if (status == null) return const SizedBox.shrink();
    final (tone, _) = connectionDisplayInfo(status);
    final online = status is Connected;
    return Padding(
      padding: const EdgeInsets.only(right: AbTokens.space6),
      child: AbStatusDot(
        tone: tone,
        style: online ? AbDotStyle.filled : AbDotStyle.hollow,
        // Pulse while mid-handshake; a settled offline (released) dot holds.
        pulse: !online && status is! Released,
      ),
    );
  }
}

/// Aggregate work-status dot for a collapsed machine header: shows only the
/// call-to-action states (attention/error) across ALL projects on [machineUuid].
/// Hidden when expanded — the machine's projects are on screen then, and their
/// session rows carry the dots — and hidden when status is working/done, keeping
/// idle machine headers clean.
class _MachineAggregateDot extends ConsumerWidget {
  const _MachineAggregateDot({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded =
        ref.watch(expandedDrawerIdsProvider).contains(machineUuid);
    if (expanded) return const SizedBox.shrink();
    final status = ref.watch(machineWorkStatusProvider(machineUuid));
    if (status == null ||
        status == AgentWorkStatus.done ||
        status == AgentWorkStatus.working) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: AbTokens.space6),
      child: AgentWorkStatusDot(status: status),
    );
  }
}

/// 8px red dot signalling the project's latest status carries an error. The
/// row owns the key so widget tests can locate the dot per-project. Tapping it
/// surfaces [ProjectStatus.configErrorMessage] in a snackbar — works on mobile
/// (no hover) where a tooltip wouldn't, and it's otherwise the only surfacing
/// of the error text. Transparent padding enlarges the touch target past the
/// 8px visual without shifting the dot.
class _ErrorDot extends StatelessWidget {
  const _ErrorDot({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: AbTokens.dotSizeMd,
      height: AbTokens.dotSizeMd,
      decoration: BoxDecoration(
        color: context.antgrid.error,
        shape: BoxShape.circle,
      ),
    );
    final msg = message;
    if (msg == null || msg.isEmpty) return dot;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showAbSnackBar(context, msg),
      child: Padding(
        padding: const EdgeInsets.all(AbTokens.space6),
        child: dot,
      ),
    );
  }
}

/// Tiny mono-text indicator that an on-demand command is currently running
/// for the project. Plan B keeps this purely informational.
class _CommandIndicator extends StatelessWidget {
  final String commandName;
  const _CommandIndicator({super.key, required this.commandName});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbIcon(AbIcons.start, size: 10, color: context.antgrid.accent),
        const SizedBox(width: AbTokens.space2),
        Text(
          commandName,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXxs,
            color: context.antgrid.accent,
          ),
        ),
      ],
    );
  }
}
