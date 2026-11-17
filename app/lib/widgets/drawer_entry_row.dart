// app/lib/widgets/drawer_entry_row.dart
import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/peer_connection.dart' show ConnectionBlockedException;
import '../connection/supervisor_state.dart';
import '../design/widgets/ab_toast.dart';
import '../models/agent_work_status.dart';
import '../models/drawer_entry.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../util/detached.dart';
import '../util/device_id.dart';
import '../project/checkout_readiness.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/checkout_readiness.dart';
import '../providers/relay_connection.dart';
import '../providers/cached_sessions.dart';
import '../providers/drawer_entries.dart';
import '../providers/new_session_action.dart'
    show openRemoteProjectForActivation;
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/recent_agents.dart';
import '../providers/sessions.dart';
import '../providers/supervisor_status.dart';
import 'ab_status_helpers.dart';
import 'carbon_confirm.dart' show showCarbonConfirm;
import 'carbon_status_dot.dart';
import 'drawer/drawer_metrics.dart';
import 'recent_sessions/recent_sessions_summary.dart' show workStatusLabel;
import 'session_isolation_badge.dart' show sessionIsIsolated;

/// A status dot is 8px on a pointer and 10px on touch, where the whole row
/// grows to 44.
const double _kTouchDotSize = 10;

double _dotSize(CarbonThemeData t) =>
    t.isTouch ? _kTouchDotSize : CarbonSpacing.spacing03;

/// A hollow liveness ring must show the row's own fill (rest, hover or
/// selected) through its middle, so it is filled with nothing.
Color _transparentFill(CarbonThemeData t) =>
    t.colors.background.withValues(alpha: 0);

/// Gives the outermost trailing mark the rail's width, so a bare dot at rest
/// centres where the actions that replace it will.
Widget _railed(BuildContext context, Widget child) {
  final t = CarbonTheme.of(context);
  if (t.isTouch) return child;
  return ConstrainedBox(
    constraints: BoxConstraints(minWidth: drawerRailCell(t)),
    child: Center(child: child),
  );
}

/// A project row's whole accessible name. The row's content is hidden from
/// semantics, so the marks it shows have to be spoken from here.
String drawerSpokenProjectName(String name, {List<String> extras = const []}) =>
    [name, ...extras].join(', ');

/// The one project row, whichever machines hold the project.
///
/// At rest the leading slot carries the folder and under a pointer a container
/// swaps it for its disclosure chevron, in the same slot so the swap never
/// shifts the title (deviation CSN-chevron). Project rows take no hover fill
/// (deviation CSN-no-hover): the fill previews selection and this row's tap
/// expands.
///
/// The hover callbacks are on one region around the whole row, actions
/// included, so moving from the title onto an action does not end the hover
/// that a prefetch is timing. The strip outside the row is not part of it.
class DrawerProjectRow extends StatelessWidget {
  const DrawerProjectRow({
    super.key,
    required this.name,
    required this.spokenName,
    required this.expanded,
    required this.warm,
    required this.onToggle,
    this.dimmed = false,
    this.error,
    this.marks = const <Widget>[],
    this.actions = const <Widget>[],
    this.keepActionsRevealed = false,
    this.onHoverStart,
    this.onHoverEnd,
  });

  final String name;
  final String spokenName;
  final bool expanded;

  /// The project holds an open session, so its folder is not dimmed.
  final bool warm;
  final VoidCallback onToggle;

  /// Every machine holding the project is offline, so its name steps down too.
  final bool dimmed;

  /// Shown beside the title rather than in the trailing slot: the trailing
  /// marks are covered by the actions under the pointer, and this one is the
  /// only way to read the error's text.
  final Widget? error;

  /// Status marks, outermost last.
  final List<Widget> marks;
  final List<Widget> actions;
  final bool keepActionsRevealed;
  final VoidCallback? onHoverStart;
  final VoidCallback? onHoverEnd;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    // Silent: the row's spoken name already carries each mark's state.
    final trailing = <Widget>[
      for (var i = 0; i < marks.length; i++)
        ExcludeSemantics(
          child: i == marks.length - 1
              ? _railed(context, marks[i])
              : marks[i],
        ),
    ];
    final row = CarbonSideNavMenu(
      title: spokenName,
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              style: dimmed ? TextStyle(color: colors.textPlaceholder) : null,
            ),
          ),
          if (error != null) ...[
            const SizedBox(width: CarbonSpacing.spacing02),
            error!,
          ],
        ],
      ),
      // Dimmed while the project holds no open session. `iconDisabled` would
      // read as a row that cannot be tapped, so the cold glyph steps down to
      // the placeholder tone instead.
      leading: CarbonIcon(
        CarbonIcons.folder,
        color: warm ? colors.iconSecondary : colors.textPlaceholder,
      ),
      expanded: expanded,
      onExpandedChanged: (_) => onToggle(),
      chevron: CarbonSideNavChevron.swapsIcon,
      hoverFill: false,
      trailing: trailing,
      actions: actions,
      keepActionsRevealed: keepActionsRevealed,
      children: const <Widget>[],
    );
    final start = onHoverStart;
    final end = onHoverEnd;
    if (start == null && end == null) return row;
    return MouseRegion(
      onEnter: (_) => start?.call(),
      onExit: (_) => end?.call(),
      child: row,
    );
  }
}

/// A work-status dot for a rollup. Only `attention` pulses: it is the one
/// status that is asking for the user, and a pulse on every rollup would dilute
/// it. The pulse is an app-level addition (see [CarbonStatusDot]).
class DrawerAttentionDot extends StatelessWidget {
  const DrawerAttentionDot({super.key, required this.status});

  final AgentWorkStatus status;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return CarbonWorkStatusDot(
      status: status,
      pulse: status == AgentWorkStatus.attention,
      size: _dotSize(t),
      semanticLabel: workStatusLabel(status),
      hollowFill: _transparentFill(t),
    );
  }
}

/// Trash affordance for removing a project/machine from history.
///
/// A LOCAL PROJECT row offers it only while the project holds no session.
/// Removing a project tears its sessions down with it, and the drawer is a
/// scanning surface where the trash sits one hover away from the row you meant
/// to open — so the sessions have to be dealt with first, deliberately, on
/// their own rows. Anything REMOTE keeps it unconditionally, band or legacy
/// per-project row alike: "Forget agent" drops cached coordinates, and the
/// machine comes back on its own while it is signed in.
///
/// `ProjectsNotifier.remove` still handles a non-empty project correctly (it
/// stops the sessions, disposes the services, then clears the selection) —
/// this is a guard rail, not a correctness fix.
class DrawerRemoveButton extends ConsumerStatefulWidget {
  final DrawerEntry entry;

  /// Held true while the menu or the confirm dialog is up. The pointer leaves
  /// the row for the menu's overlay and then the modal, and without the latch
  /// the actions would hide under their own menu or dialog.
  final ValueChanged<bool>? onLatch;

  const DrawerRemoveButton({super.key, required this.entry, this.onLatch});

  /// Whether [entry] has a trash to offer at all. Asked by the row rather than
  /// answered by a self-shrinking build, because the trailing kit reserves the
  /// outermost cell for whatever is genuinely last.
  static bool offersFor(WidgetRef ref, DrawerEntry entry) {
    // Inventory agents have no locally-stored state to remove (they're managed
    // server-side).
    if (entry is InventoryAgentEntry) return false;
    // LOCAL projects only. A legacy per-project REMOTE row also has a null
    // `machineUuid`, but its trash is "Forget agent" — the cheap, self-healing
    // drop of cached coordinates a machine band keeps unconditionally — so
    // gating it there would strand a row whose machine is gone with no way to
    // clear the very cache that hides the button.
    //
    // A project nobody has opened has an empty cache and so reads as empty
    // here; the confirm dialog is what covers that case, and it names what
    // will be lost. Selected down to the bool: this is asked for every drawer
    // row, and the list identity changes on every `session:updated` of the
    // focused project.
    if (entry is LocalProjectEntry &&
        ref.watch(
          sessionsForEntryProvider(
            entry.id,
          ).select((s) => s.any((e) => !e.archived)),
        )) {
      return false;
    }
    return true;
  }

  @override
  ConsumerState<DrawerRemoveButton> createState() => _DrawerRemoveButtonState();
}

class _DrawerRemoveButtonState extends ConsumerState<DrawerRemoveButton> {
  // Self-disable while a confirmed removal's async teardown is in flight so a
  // second tap can't re-enter `_confirmRemove`.
  bool _busy = false;

  // Owned so focus can be put back on a live node: the menu's own restore
  // target is an overlay item that is gone by the time the menu closes.
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'drawer remove menu');

  // The package does not report a close when the trigger unmounts under an
  // open menu, so the latch it took would never be released.
  bool _menuOpen = false;

  bool _modalOpen = false;

  void _onMenuOpenChanged(bool open) {
    _menuOpen = open;
    if (open) {
      widget.onLatch?.call(true);
      return;
    }
    _restoreFocus();
    // An item's callback follows this close in the same event and takes the
    // latch back for its modal, so the release waits to see whether it did.
    _releaseLatchAfterFrame(() => !_modalOpen);
  }

  // The row learns that focus now sits on the trigger only after a frame, so
  // releasing the latch at once hides the actions, and the trigger with them,
  // just after it was handed focus.
  void _releaseLatchAfterFrame(bool Function() stillWanted) {
    final onLatch = widget.onLatch;
    if (onLatch == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (stillWanted()) onLatch(false);
    });
  }

  // Asked twice: the menu and the modal route each restore their own captured
  // focus target as they unwind, after this runs, and neither target survives.
  void _restoreFocus() {
    void request() {
      if (!mounted || !_triggerFocus.canRequestFocus) return;
      _triggerFocus.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    }

    request();
    WidgetsBinding.instance.addPostFrameCallback((_) => request());
  }

  @override
  void dispose() {
    final onLatch = widget.onLatch;
    if (_menuOpen && onLatch != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onLatch(false));
    }
    _triggerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.entry is LocalProjectEntry;
    final cell = drawerRailCell(CarbonTheme.of(context));
    // The cell is the rail's square. Carbon's extra-small trigger is exactly
    // that box on a pointer and a full touch target on touch, so the trigger
    // fills it and what paints is what takes the tap.
    return SizedBox(
      key: const ValueKey('drawer-remove-cell'),
      width: cell,
      height: cell,
      child: CarbonOverflowMenu(
        semanticLabel: 'Actions for ${widget.entry.displayName}',
        enabled: !_busy,
        size: CarbonButtonSize.extraSmall,
        focusNode: _triggerFocus,
        // The menu's overlay sits outside the row's hover region, so the
        // pointer crossing into it would un-reveal the row. The latch holds
        // the actions visible for as long as the menu is up.
        onOpenChanged: _onMenuOpenChanged,
        entries: [
          CarbonMenuItem(
            label: isLocal ? 'Remove from history' : 'Forget agent',
            kind: CarbonMenuItemKind.danger,
            onPressed: () => detached(
              'DrawerEntryRow',
              'remove project',
              _confirmRemove,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove() async {
    final entry = widget.entry;
    // Captured before the dialog await: the removal below must still run if the
    // drawer rebuilt this row away while the confirm was open.
    final container = ref.container;
    final onLatch = widget.onLatch;
    onLatch?.call(true);
    _modalOpen = true;
    // The modal route restores whatever held focus when it opened, and at this
    // point that is the menu item, which dies with the menu overlay.
    _triggerFocus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    try {
      await confirmRemoveDrawerEntry(
        context,
        container,
        entry,
        // No `mounted` EARLY RETURN here, only a guarded setState: a confirmed
        // destructive action runs off the captured container, and bailing out
        // because the row was rebuilt away would turn a Yes into a silent no-op.
        onConfirmed: () {
          if (mounted) setState(() => _busy = true);
        },
      );
    } finally {
      // The row is usually gone after removal (entry dropped from the drawer);
      // guard the setState so we don't touch a disposed State.
      if (mounted) setState(() => _busy = false);
      _modalOpen = false;
      _restoreFocus();
      _releaseLatchAfterFrame(() => !_modalOpen && !_menuOpen);
    }
  }
}

/// Asks to remove [entry] from history (a local project) or forget it (a
/// remote machine), and does it on a Yes. [onConfirmed] runs between the Yes
/// and the teardown, for a caller that disables itself while it runs.
///
/// Takes the [ProviderContainer] rather than a `WidgetRef`: the removal must
/// still run when the row that asked was rebuilt away while the dialog was up.
Future<void> confirmRemoveDrawerEntry(
  BuildContext context,
  ProviderContainer container,
  DrawerEntry entry, {
  VoidCallback? onConfirmed,
}) async {
  final isLocal = entry is LocalProjectEntry;
  final ok = await showCarbonConfirm(
    context,
    title: isLocal
        ? 'Remove ${entry.displayName}?'
        : 'Forget ${entry.displayName}?',
    body: isLocal
        ? removeLocalProjectBody(container, entry.id)
        : 'This clears the cached sessions and connection details for '
              'this machine. It comes back on its own while it is signed '
              'in to your account.',
    confirmLabel: isLocal ? 'Remove' : 'Forget',
    danger: true,
  );
  if (!ok) return;
  onConfirmed?.call();
  switch (entry) {
    case LocalProjectEntry e:
      // `ProjectsNotifier.remove` owns the local teardown: it stops the
      // project's sessions/terminals, disposes its services + transport, then
      // forgets the record.
      await container.read(projectsProvider.notifier).remove(e.id);
    case RemoteAgentEntry e:
      await container
          .read(machineConnectionProvider.notifier)
          .forgetMachine(e.agent.agentDeviceId);
    case InventoryAgentEntry _:
      // Inventory agents are not stored locally — nothing to remove. The entry
      // will disappear from the list when the account inventory is next
      // refreshed or the device is deleted server-side.
      break;
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

/// User-facing copy for a failed dial.
///
/// Matched on the structured block reason rather than interpolating the error,
/// because everything that reaches here is a developer string: a bare
/// `'Connect failed: $e'` puts `ConnectionBlockedException(handshakeFailing)`
/// (or a raw `TimeoutException`) in a snackbar. The generic arm carries no
/// detail for the same reason — the connection error screen is where a reason
/// belongs, and it has one.
String connectFailureMessage(Object error) => switch (error) {
  ConnectionBlockedException(reason: final reason) => blockReasonPresentation(
    reason,
  ).connectFailure,
  _ => 'Connect failed.',
};

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
    final ra = ref
        .read(recentAgentsProvider)
        .firstWhere((r) => r.agentDeviceId == agentDeviceId);
    // No rendezvous: reading the machine's transport declares the connection
    // wanted and hands the supervisor the ladder (dial → presence → session
    // handshake as this app's own DeviceRecord). It throws with the block
    // reason when the supervisor gives up, which is what the snackbar reports.
    await ref.read(agentTransportForProvider(ra.agentDeviceId).future);
    ref
        .read(selectedTargetProvider.notifier)
        .set(RemoteTarget.legacy(ra.agentDeviceId));
    return true;
  } catch (e) {
    if (context.mounted) {
      showAbToast(context, connectFailureMessage(e));
    }
    return false;
  }
}

/// Reconnects the live remote target if its transport is currently offline.
/// Skips on `connecting` so we don't race an in-flight connect.
///
/// [registrationId] is whatever the caller already has focused — a machine's
/// bare uuid, or a remote project's `<machineUuid>.<projectId>`. Reading that
/// id's transport is what declares the connection wanted and hands the
/// supervisor the ladder; it throws with the block reason when the supervisor
/// gives up, which is what the snackbar reports.
///
/// Deliberately NOT [selectRemoteAgent]: that resolves a MACHINE record and
/// sets the focus to it, so a compound project id found no record (its
/// `firstWhere` threw `Bad state: No element` straight into the snackbar) and
/// the machine it would have focused on success is not the project the user is
/// looking at. Nothing here writes the focus — the caller already has the one
/// it wants.
Future<bool> ensureRemoteOnline(
  BuildContext context,
  ProviderContainer ref,
  String registrationId,
) async {
  final status = ref.read(supervisorStatusProvider(registrationId)).value;
  if (status is! Blocked) return true;
  // A block is sticky. This user action is the explicit Retry that clears it;
  // rebuilding the provider alone would only replay the same verdict.
  ref.read(relayConnectionManagerProvider).peek(registrationId)?.retry();
  ref.invalidate(agentTransportForProvider(registrationId));
  try {
    // Null is a machine no source can name coordinates for (dropped from the
    // inventory, never in the reconnect list). Reporting that as online sends
    // the caller into a warm-up that can only time out in silence.
    if (await ref.read(agentTransportForProvider(registrationId).future) ==
        null) {
      if (context.mounted) {
        showAbToast(context, 'That machine is no longer reachable.');
      }
      return false;
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showAbToast(context, connectFailureMessage(e));
    }
    return false;
  }
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
/// What to tell someone who tapped the machine that is already being dialled.
///
/// Spelled out per state rather than lower-casing [readinessDisplayInfo]: those
/// labels are written to stand alone in a chip, and two of them turn into
/// nonsense behind "still" — the chip's verdicts read as progress reports here.
String _stillWaitingMessage(ProviderContainer ref) =>
    switch (ref.read(checkoutReadinessProvider)) {
      CheckoutReadiness.reachingMachine => 'still reaching the machine…',
      CheckoutReadiness.openingSession => 'still opening the session…',
      CheckoutReadiness.loadingScreen => 'still loading the terminal…',
      CheckoutReadiness.stalled => "couldn't load — retry from the terminal",
      // Reached while the ladder is mid-climb and nothing has answered yet, so
      // the tap is not being ignored — it is the same wait, still running.
      CheckoutReadiness.cold ||
      CheckoutReadiness.blocked ||
      CheckoutReadiness.ready => 'still connecting…',
    };

Future<bool> activateDrawerEntryById(
  BuildContext context,
  ProviderContainer ref,
  String entryId,
) async {
  final entries = ref.read(drawerEntriesProvider);
  final entry = entries.where((e) => e.id == entryId).firstOrNull;
  // Drop a duplicate tap on the machine whose connection is already mid-flight.
  // Every reachability provider here reads the FOCUS, so the guard only holds
  // while the focused machine IS the tapped one — otherwise one machine dialling
  // would swallow every tap on all the others. Gated on `focusedIsRelayProvider`
  // because `agentReachabilityProvider` returns `connecting` by default
  // whenever no agent is active (including pure local mode), which would
  // otherwise block every tap. Gated on `focusedAgentBlockedProvider` because
  // a blocked ladder also reads `connecting` and never leaves it on its own:
  // without this the tap is a silent no-op forever and the user can never
  // reach the error surface that holds Retry.
  if (entry is RemoteAgentEntry || entry is InventoryAgentEntry) {
    final focusedId = ref.read(selectedRegistrationIdProvider);
    final sameMachine =
        focusedId != null &&
        baseDeviceUuid(focusedId) == baseDeviceUuid(entryId);
    if (sameMachine &&
        ref.read(focusedIsRelayProvider) &&
        !ref.read(focusedAgentBlockedProvider) &&
        ref.read(agentReachabilityProvider) == AgentReachability.connecting) {
      if (context.mounted) {
        showAbToast(context, _stillWaitingMessage(ref));
      }
      return false;
    }
  }

  // Stamped only once the tap is going to do something: the guard above returns
  // on a re-tap of the machine already being dialled, and stamping before it
  // would snap the wait readout back to zero for a user who has been watching
  // the same activation the whole time.
  ref
      .read(focusedWaitStartedAtProvider.notifier)
      .set(DateTime.now().millisecondsSinceEpoch);

  if (entry == null) {
    // A session row nested under a remote MACHINE entry carries its project's
    // compound `<uuid>.<projectId>` regId, which is not itself a drawer entry
    // (the entry is the bare-uuid machine). When that project is already open
    // (warm transport), refocus it as a remote target — nothing to dial.
    if (_focusOpenRemoteProject(ref, entryId)) return true;
    // A cold (advertised-but-not-warm) project still needs its machine dialled,
    // then promotion and a data-plane socket, before it can be focused —
    // `_focusOpenRemoteProject` only refocuses one that is already warm.
    return _openColdRemoteProject(context, ref, entryId);
  }

  bool ok;
  switch (entry) {
    case LocalProjectEntry e:
      // The sample project falls out inside ProjectStore.upsert, which is the
      // choke point every writer shares — nothing here needs to know.
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
      // Same-account machine straight from the peers inventory. Reading its
      // transport brings the supervisor up; the agent admits us from the
      // inventory when the session handshake lands.
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
          showAbToast(context, connectFailureMessage(ex));
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
/// regId) from a drawer session-row tap: dials the machine, promotes it
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
  } catch (e) {
    ref.read(selectedTargetProvider.notifier).set(priorTarget);
    if (context.mounted) {
      showAbToast(context, connectFailureMessage(e));
    }
    return false;
  }
}
