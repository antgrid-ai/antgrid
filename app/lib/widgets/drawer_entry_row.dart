// app/lib/widgets/drawer_entry_row.dart
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/peer_connection.dart' show ConnectionBlockedException;
import '../connection/supervisor_state.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_toast.dart';
import '../models/drawer_entry.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../util/device_id.dart';
import '../project/checkout_readiness.dart';
import '../project/limits.dart';
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
import 'session_isolation_badge.dart' show sessionIsIsolated;

/// Shared hover shell for drawer rows: the gutter [Padding] kept outside the
/// [MouseRegion] (so the L/R strips aren't hover/tap-reactive), the click cursor,
/// and the hover bits both row variants drive. [onHoverStart]/[onHoverEnd] let a
/// row hang extra work (e.g. a prefetch timer) off the desktop pointer
/// transitions; they never fire on mobile.
///
/// The builder gets TWO bits, and they differ only on touch. `hovered` gates
/// hover-revealed AFFORDANCES and starts true on mobile, which has no pointer to
/// reveal them with. `pointerOver` is the literal pointer state and stays false
/// there — a row that swaps its identity glyph for a chevron must key off this
/// one, or the glyph is permanently swapped on every phone and never shows at
/// all.
class HoverableDrawerRow extends StatefulWidget {
  const HoverableDrawerRow({
    super.key,
    required this.builder,
    this.above,
    this.onHoverStart,
    this.onHoverEnd,
  });

  /// Chrome that belongs to this row's block but must not be hover-reactive:
  /// it sits inside the gutter, above the [MouseRegion]. Kept out of [builder]
  /// so the pointer neither reveals the row's hover affordances from over it
  /// nor rebuilds it.
  final Widget? above;

  final Widget Function(BuildContext context, bool hovered, bool pointerOver)
  builder;
  final VoidCallback? onHoverStart;
  final VoidCallback? onHoverEnd;

  @override
  State<HoverableDrawerRow> createState() => _HoverableDrawerRowState();
}

class _HoverableDrawerRowState extends State<HoverableDrawerRow> {
  bool _pointerOver = false;

  /// Affordance visibility. Mobile has no pointer, so they start visible.
  bool get _hovered => isMobilePlatform || _pointerOver;

  void _onEnter(PointerEnterEvent _) {
    if (isMobilePlatform) return;
    if (!_pointerOver && mounted) setState(() => _pointerOver = true);
    widget.onHoverStart?.call();
  }

  void _onExit(PointerExitEvent _) {
    if (isMobilePlatform) return;
    if (_pointerOver && mounted) setState(() => _pointerOver = false);
    widget.onHoverEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final region = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: _onEnter,
      onExit: _onExit,
      child: widget.builder(context, _hovered, _pointerOver),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.drawerGutter),
      child: widget.above == null
          ? region
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [widget.above!, region],
            ),
    );
  }
}

/// The leading slot of a PROJECT row, local or advertised-remote alike.
///
/// One rule for the whole drawer: at rest the slot carries the row's identity
/// glyph, and under the pointer a container swaps it for its disclosure
/// chevron. Both are boxed to [AbTokens.drawerLeadingSlot] at the same glyph
/// size, so the swap never shifts the title.
class DrawerProjectLeading extends StatelessWidget {
  const DrawerProjectLeading({
    super.key,
    required this.expanded,
    required this.pointerOver,
    required this.warm,
  });

  final bool expanded;
  final bool pointerOver;

  /// The project holds an open session — see [_leadingTint].
  final bool warm;

  @override
  Widget build(BuildContext context) {
    final tint = _leadingTint(context, warm);
    if (pointerOver) {
      return AbDisclosureChevron(expanded: expanded, color: tint);
    }
    return SizedBox(
      width: AbTokens.drawerLeadingSlot,
      height: AbTokens.drawerLeadingSlot,
      child: Center(
        // Match chevron size so the glyph doesn't shrink on hover.
        child: AbIcon(AbIcons.folder, size: 10, color: tint),
      ),
    );
  }
}

/// Title style for a PROJECT row. Weight, not size, is what makes it read as
/// the container of the session rows beneath it: those are the payload the user
/// is scanning for and stay the largest text in the panel, so a project that
/// out-sized them would invert the hierarchy it is supposed to anchor.
TextStyle drawerProjectTitleStyle(BuildContext context) => AbTokens.sansStyle(
  fontSize: AbTokens.fontSm,
  fontWeight: FontWeight.w600,
  color: context.antgrid.textSecondary,
);

/// Leading-glyph tint for a drawer row, dimmed while the project holds no open
/// session.
///
/// Baked into the colour rather than applied with `Opacity`, which would
/// composite a layer per row to reach the same pixels.
Color _leadingTint(BuildContext context, bool isWarm) {
  final muted = context.antgrid.textMuted;
  return isWarm ? muted : muted.withValues(alpha: muted.a * 0.6);
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

  /// Held true while the confirm dialog is up. The row that revealed this
  /// button collapses on pointer-exit, and the pointer leaves it the moment the
  /// modal opens — without the latch the trash unmounts under its own dialog.
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

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.entry is LocalProjectEntry;
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
    final onLatch = widget.onLatch;
    onLatch?.call(true);
    try {
      final ok = await AbConfirmDialog.show(
        context: context,
        title: isLocal
            ? 'Remove ${entry.displayName}?'
            : 'Forget ${entry.displayName}?',
        body: isLocal
            ? removeLocalProjectBody(container, entry.id)
            : 'This clears the cached sessions and connection details for '
                  'this machine. It comes back on its own while it is signed '
                  'in to your account.',
        confirmLabel: isLocal ? 'Remove' : 'Forget',
        destructive: true,
      );
      if (!ok) return;
      // No `mounted` EARLY RETURN here, only a guarded setState: a confirmed
      // destructive action runs off the captured container, and bailing out
      // because the row was rebuilt away would turn a Yes into a silent no-op.
      if (mounted) setState(() => _busy = true);
      try {
        switch (entry) {
          case LocalProjectEntry e:
            // `ProjectsNotifier.remove` owns the local teardown: it stops the
            // project's sessions/terminals, disposes its services + transport,
            // then forgets the record.
            await container.read(projectsProvider.notifier).remove(e.id);
          case RemoteAgentEntry e:
            await container
                .read(machineConnectionProvider.notifier)
                .forgetMachine(e.agent.agentDeviceId);
          case InventoryAgentEntry _:
            // Inventory agents are not stored locally — nothing to remove.
            // The entry will disappear from the list when the account inventory
            // is next refreshed or the device is deleted server-side.
            break;
        }
      } finally {
        // The row is usually gone after removal (entry dropped from the
        // drawer); guard the setState so we don't touch a disposed State.
        if (mounted) setState(() => _busy = false);
      }
    } finally {
      onLatch?.call(false);
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
