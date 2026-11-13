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
import '../models/memory.dart';
import 'memory/memory_project_button.dart';
import '../launcher/host_controller.dart' show HostPhase;
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../util/detached.dart';
import '../util/device_id.dart';
import '../project/checkout_readiness.dart';
import '../project/limits.dart';
import '../project/perf_recorder.dart';
import '../project/project_session_registry.dart';
import '../project/project_status.dart';
import '../providers/agent_transport.dart';
import '../providers/checkout_readiness.dart';
import '../providers/relay_connection.dart';
import '../providers/cached_sessions.dart';
import '../providers/demo_mode.dart';
import '../providers/drawer_entries.dart';
import '../providers/collapsed_drawer.dart';
import '../providers/drawer_expansion.dart';
import '../providers/host_status.dart';
import '../providers/new_session_action.dart'
    show openRemoteProjectForActivation;
import '../providers/new_session_picker.dart'
    show
        enterNewSession,
        enterNewSessionForRemoteProject,
        selectedSourceIdProvider,
        selectedTargetProjectProvider;
import '../providers/project_work_status.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/recent_agents.dart';
import '../providers/sessions.dart';
import '../providers/supervisor_status.dart';
import '../services/control_plane_client.dart' show AdvertisedProject;
import 'ab_status_helpers.dart';
import 'agent_work_status_dot.dart' show agentWorkStatusNeedsUser;
import 'carbon_confirm.dart' show showCarbonConfirm;
import 'carbon_status_dot.dart';
import 'drawer/drawer_metrics.dart';
import 'projects_drawer.dart' show closeDrawerIfOverlay;
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

/// The square a liveness mark is centred in, so every band's mark sits on the
/// same rail as the glyphs of the rows beneath it. Reserved whether or not a
/// mark renders, so a socket resolving cannot shift the rail.
Widget _livenessCell(BuildContext context, {Widget? child}) {
  final cell = drawerRailCell(CarbonTheme.of(context));
  return SizedBox(
    width: cell,
    height: cell,
    child: child == null ? null : Center(child: child),
  );
}

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

/// One row in the projects drawer.
class DrawerEntryRow extends ConsumerStatefulWidget {
  final DrawerEntry entry;
  const DrawerEntryRow(this.entry, {super.key});

  @override
  ConsumerState<DrawerEntryRow> createState() => _DrawerEntryRowState();
}

/// Section BAND for a remote machine in the drawer, not a tree node.
///
/// A machine is a container of projects, not a project, and treating it as a
/// third level of tree cost an indent step that every session name underneath
/// then paid for out of a 288px panel. As a band it costs nothing: the projects
/// below it sit where a LOCAL project sits, which is what lets one project row
/// serve both. Upstream's side nav has two tiers and no third, so the band is
/// an app-level addition that reuses the menu row.
///
/// Carries no `REMOTE` tag. Remote is encoded by which band a project is
/// under, and repeating it on the band that already names the machine says
/// nothing.
///
/// Stateful for the reveal bit a pointer cannot supply: the latch a confirm
/// dialog holds while it is up.
class MachineDrawerHeaderRow extends ConsumerStatefulWidget {
  final DrawerEntry entry;

  /// Hairline above, separating this machine's block from whatever precedes
  /// it. False for the first band in the drawer, which already has the
  /// `Projects` header above it.
  final bool showRule;

  const MachineDrawerHeaderRow(this.entry, {super.key, this.showRule = true});

  @override
  ConsumerState<MachineDrawerHeaderRow> createState() =>
      _MachineDrawerHeaderRowState();
}

class _MachineDrawerHeaderRowState
    extends ConsumerState<MachineDrawerHeaderRow> {
  bool _latched = false;

  // Marks come and go ahead of the action cell, and a positional rebuild would
  // remount the action and drop its menu's focus and open state.
  final _removeKey = GlobalKey();

  void _setLatched(bool v) {
    if (!mounted || _latched == v) return;
    setState(() => _latched = v);
  }

  @override
  Widget build(BuildContext context) {
    perfRecorder.noteDrawerRebuild();
    final entry = widget.entry;
    final machineUuid = entry.machineUuid!;
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(machineUuid);
    final offersRemove = _RemoveButton.offersFor(ref, entry);
    final conflict =
        ref.watch(centralControlConflictProvider(machineUuid)).value ?? false;
    final status =
        ref.watch(projectStatusProvider(entry.id)).value ??
        const ProjectStatus.empty();

    return _MachineBand(
      label: entry.displayName,
      icon: CarbonIcons.serverDns,
      // Kept on the band, unlike the local one: expanding a machine is what
      // opens its control-plane socket, so there is something to disclose.
      expanded: expanded,
      showRule: widget.showRule,
      onToggle: () =>
          ref.read(expandedDrawerIdsProvider.notifier).toggle(machineUuid),
      keepActionsRevealed: _latched,
      // The liveness mark owns the rail cell and the trash swaps into it, so
      // collapsing the action cannot slide the mark on pointer-enter and a
      // second cell cannot push the trash inboard of every other row's.
      error: status.configError
          ? _ConfigErrorMark(
              key: ValueKey('drawer-error-dot-${entry.id}'),
              message: status.configErrorMessage,
            )
          : null,
      // The retry control sits in this slot, which a swap would cover and
      // unfocus the moment the row is revealed.
      actionsMode: conflict
          ? CarbonSideNavActions.reserved
          : CarbonSideNavActions.swap,
      trailing: [
        if (status.activeCommandName != null)
          _CommandTag(
            key: ValueKey('drawer-cmd-indicator-${entry.id}'),
            commandName: status.activeCommandName!,
          ),
        _MachineAggregateDot(machineUuid: machineUuid),
        _MachineOnlineMark(machineUuid: machineUuid),
      ],
      actions: [
        if (offersRemove)
          _RemoveButton(key: _removeKey, entry: entry, onLatch: _setLatched),
      ],
    );
  }
}

/// The band above THIS machine's local projects.
///
/// Exists so a local project and a remote one are the same row at the same
/// indent under the same kind of header. It also gives the local bridge host
/// the only status surface it has in the drawer.
///
/// Tappable to fold every local project away ([localMachineCollapsedProvider]).
/// Unlike a remote band the chevron discloses no fetch, because the projects
/// are already known, so the fold is purely for scanning density, and is
/// remembered across launches like a project row's.
class LocalMachineBand extends ConsumerWidget {
  const LocalMachineBand({super.key, this.showRule = true});

  final bool showRule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MachineBand(
      label: 'This machine',
      icon: CarbonIcons.laptop,
      expanded: !ref.watch(localMachineCollapsedProvider),
      showRule: showRule,
      onToggle: () => toggleLocalMachineCollapsed(ref),
      // No host mark under the demo: there is no bridge behind the sample
      // project, and [hostStatusProvider] answers for the REAL machine, which
      // on a desktop that opened a project earlier in the session is a live
      // green dot pinned to a project it has nothing to do with. Every other
      // real-source surface in this drawer is gated the same way.
      trailing: [
        if (ref.watch(demoModeProvider))
          _livenessCell(context)
        else
          const _LocalHostMark(),
      ],
    );
  }
}

/// The shared band: an optional hairline, then a menu row whose label sits in
/// `label` type and whose liveness rides the trailing slot.
class _MachineBand extends StatelessWidget {
  const _MachineBand({
    required this.label,
    required this.icon,
    required this.expanded,
    required this.onToggle,
    required this.showRule,
    this.trailing = const <Widget>[],
    this.actions = const <Widget>[],
    this.actionsMode = CarbonSideNavActions.swap,
    this.error,
    this.keepActionsRevealed = false,
  });

  final String label;
  final CarbonIcons icon;
  final bool expanded;
  final VoidCallback onToggle;
  final bool showRule;
  final List<Widget> trailing;
  final List<Widget> actions;

  /// `reserved` when the trailing slot holds a control: swap mode covers and
  /// unfocuses the trailing marks while the row is revealed.
  final CarbonSideNavActions actionsMode;

  /// Shown beside the label rather than trailing, for the same reason.
  final Widget? error;
  final bool keepActionsRevealed;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A SIBLING above the row rather than part of it, so the strip it
        // occupies is not inside the row's hover region and cannot pop the
        // hover-revealed trash out of dead space.
        if (showRule)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: CarbonSpacing.spacing05,
              end: CarbonSpacing.spacing05,
              top: CarbonSpacing.spacing03,
              bottom: CarbonSpacing.spacing02,
            ),
            child: SizedBox(
              width: double.infinity,
              height: CarbonBorders.hairline,
              child: ColoredBox(color: t.borderSubtle(0)),
            ),
          ),
        CarbonSideNavMenu(
          title: label,
          // The label keeps the casing it was given: a band names a MACHINE,
          // and a machine name is the user's own noun. `inherit` lets the
          // row's state colour reach a style that carries none of its own.
          // Shrink-wrapped so the disclosure chevron, which follows this
          // content directly, sits against the name instead of the row's end.
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  style: t.typography.label.copyWith(inherit: true),
                ),
              ),
              if (error != null) ...[
                const SizedBox(width: CarbonSpacing.spacing02),
                error!,
              ],
            ],
          ),
          // The row paints a menu's glyph emphasised, which suits an active
          // item and not a heading.
          leading: CarbonIcon(icon, color: t.colors.iconSecondary),
          expanded: expanded,
          onExpandedChanged: (_) => onToggle(),
          // Beside the name, so the trailing slot belongs to the liveness mark
          // alone and the band reads as a disclosure of its machine.
          chevron: CarbonSideNavChevron.afterLabel,
          // A band is a section heading and the project rows it contains take
          // no fill, so a heading that lit under the pointer would be the
          // loudest surface in its own section.
          hoverFill: false,
          trailing: trailing,
          actions: actions,
          actionsMode: actionsMode,
          keepActionsRevealed: keepActionsRevealed,
          children: const <Widget>[],
        ),
      ],
    );
  }
}

/// Bridge-host liveness for [LocalMachineBand], mapped from [HostPhase].
///
/// `idle` and `stopped` render NOTHING rather than a ring: neither is a
/// fault, because the host is spawned on demand, so before the first project
/// is opened there is simply nothing to report, and a ring there reads as
/// "your machine is offline" on a machine the user is sitting at.
class _LocalHostMark extends ConsumerWidget {
  const _LocalHostMark();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(hostStatusProvider).value?.phase;
    final t = CarbonTheme.of(context);
    final (liveness, label) = switch (phase) {
      HostPhase.up => (DrawerLiveness.connected, 'Bridge running'),
      HostPhase.starting ||
      HostPhase.restarting => (DrawerLiveness.connecting, 'Bridge starting'),
      HostPhase.failed => (DrawerLiveness.failed, 'Bridge failed'),
      _ => (null, ''),
    };
    if (liveness == null) return _livenessCell(context);
    return _livenessCell(
      context,
      child: CarbonLivenessDot(
        liveness: liveness,
        size: _dotSize(t),
        semanticLabel: label,
        hollowFill: _transparentFill(t),
      ),
    );
  }
}

class _DrawerEntryRowState extends ConsumerState<DrawerEntryRow> {
  Timer? _prefetchTimer;
  bool _latched = false;

  // Marks come and go ahead of the action cell, and a positional rebuild would
  // remount an action and drop its menu's open state or a tap's busy guard.
  final _removeKey = GlobalKey();
  final _newSessionKey = GlobalKey();

  void _setLatched(bool v) {
    if (!mounted || _latched == v) return;
    setState(() => _latched = v);
  }

  void _startPrefetch() {
    // Hover is the desktop pointer's; a touch row has none to prefetch on.
    if (isMobilePlatform) return;
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
    final status =
        ref.watch(projectStatusProvider(entry.id)).value ??
        const ProjectStatus.empty();
    final offersRemove = _RemoveButton.offersFor(ref, entry);
    // A collapsed project still says whether something inside it needs the
    // user: that is a call to action, and the sessions that would carry it are
    // off screen. It does NOT say how many sessions it holds, because a count
    // is a number to read rather than a state to notice and the drawer is
    // scanned. Expanded, the session rows carry it.
    final needsUser =
        !expanded && DrawerProjectAggregateDot.needsUser(ref, entry.id);
    final work = ref.watch(projectWorkStatusProvider(entry.id));
    // No per-machine "New session" +: a machine is a container, not a project,
    // so a session must name a project. The + lives on each advertised project
    // row instead (see [AdvertisedProjectRow]).
    final offersNewSession = machineUuid == null;
    final isRemote = entry.kind == EntryKind.remote;
    final configMessage = status.configErrorMessage;

    return _ProjectRow(
      name: entry.displayName,
      spokenName: _spokenProjectName(
        entry.displayName,
        extras: [
          if (status.configError)
            (configMessage == null || configMessage.isEmpty)
                ? 'Config error'
                : 'Config error: $configMessage',
          if (status.activeCommandName != null)
            'running ${status.activeCommandName}',
          if (needsUser) workStatusLabel(work),
          if (isRemote) 'Remote',
        ],
      ),
      expanded: expanded,
      warm: isWarm,
      onToggle: () => machineUuid != null
          ? ref.read(expandedDrawerIdsProvider.notifier).toggle(machineUuid)
          : ref.read(collapsedDrawerIdsProvider.notifier).toggle(entry.id),
      error: status.configError
          ? _ConfigErrorMark(
              key: ValueKey('drawer-error-dot-${entry.id}'),
              message: configMessage,
            )
          : null,
      marks: [
        if (status.activeCommandName != null)
          _CommandTag(
            key: ValueKey('drawer-cmd-indicator-${entry.id}'),
            commandName: status.activeCommandName!,
          ),
        if (needsUser) DrawerProjectAggregateDot(entryId: entry.id),
        if (isRemote) const _RemoteTag(),
      ],
      // New session, Memory, then the remove menu outermost on the rail: the
      // order the approved drawer design draws on every project row.
      actions: [
        if (offersNewSession)
          _NewSessionButton(
            key: _newSessionKey,
            entry: entry,
            onLatch: _setLatched,
          ),
        if (offersNewSession) _memoryButton(entry),
        if (offersRemove)
          _RemoveButton(key: _removeKey, entry: entry, onLatch: _setLatched),
      ],
      keepActionsRevealed: _latched,
      onHoverStart: _startPrefetch,
      onHoverEnd: _cancelPrefetch,
    );
  }

  static Widget _memoryButton(DrawerEntry entry) {
    // A legacy compound id is `<machineUuid>.<projectId>`; a leading dot has no
    // machine part, so it is not one.
    if (entry is RemoteAgentEntry && entry.id.indexOf('.') > 0) {
      return MemoryProjectButton(
        target: MemoryTarget.machine(machineId: baseDeviceUuid(entry.id)),
        projectId: baseProjectId(entry.id),
        projectName: entry.displayName,
      );
    }
    return MemoryProjectButton(
      target: const MemoryTarget.machine(),
      projectId: entry.id,
      projectName: entry.displayName,
    );
  }
}

/// A project row's whole accessible name. The row's content is hidden from
/// semantics, so the marks it shows have to be spoken from here.
String _spokenProjectName(String name, {List<String> extras = const []}) =>
    [name, ...extras].join(', ');

/// The one project row, local or advertised-remote alike, so the two halves of
/// the drawer are a single grammar.
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
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.name,
    required this.spokenName,
    required this.expanded,
    required this.warm,
    required this.onToggle,
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
          Flexible(child: Text(name)),
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

/// Aggregate work-status dot for a COLLAPSED project row, local or
/// advertised-remote alike: the same narrow call-to-action set
/// [_MachineAggregateDot] shows, for the same reason.
///
/// The rule that drawer project rows carry no dot is about the EXPANDED case:
/// a rollup sitting beside the session rows it summarises only restated
/// whichever of them was loudest. Collapsed, those rows are not on screen, and
/// a session that needs the user has no other way to say so.
class DrawerProjectAggregateDot extends ConsumerWidget {
  const DrawerProjectAggregateDot({super.key, required this.entryId});

  final String entryId;

  /// Whether [entryId] has anything to say. The caller asks BEFORE building the
  /// dot, because a trailing kit that drops absent children has to know they
  /// are absent: a widget that shrinks itself away still occupies a slot and
  /// its gap.
  static bool needsUser(WidgetRef ref, String entryId) =>
      agentWorkStatusNeedsUser(ref.watch(projectWorkStatusProvider(entryId)));

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _AttentionDot(status: ref.watch(projectWorkStatusProvider(entryId)));
}

/// A work-status dot for a rollup. Only `attention` pulses: it is the one
/// status that is asking for the user, and a pulse on every rollup would dilute
/// it. The pulse is an app-level addition (see [CarbonStatusDot]).
class _AttentionDot extends StatelessWidget {
  const _AttentionDot({required this.status});

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

/// The small tag that says a legacy per-project row lives on another machine.
class _RemoteTag extends StatelessWidget {
  const _RemoteTag();

  @override
  Widget build(BuildContext context) => const CarbonTag(
    label: 'Remote',
    size: CarbonTagSize.small,
    color: CarbonTagColor.outline,
  );
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
class _RemoveButton extends ConsumerStatefulWidget {
  final DrawerEntry entry;

  /// Held true while the menu or the confirm dialog is up. The pointer leaves
  /// the row for the menu's overlay and then the modal, and without the latch
  /// the actions would hide under their own menu or dialog.
  final ValueChanged<bool>? onLatch;

  const _RemoveButton({super.key, required this.entry, this.onLatch});

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
  ConsumerState<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends ConsumerState<_RemoveButton> {
  // Self-disable while a confirmed removal's async teardown is in flight so a
  // second tap can't re-enter `_confirmRemove` (matching `_NewSessionButton`).
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
              () => _confirmRemove(isLocal: isLocal),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove({required bool isLocal}) async {
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
      final title = isLocal
          ? 'Remove ${entry.displayName}?'
          : 'Forget ${entry.displayName}?';
      final body = isLocal
          ? removeLocalProjectBody(container, entry.id)
          : 'This clears the cached sessions and connection details for '
                'this machine. It comes back on its own while it is signed '
                'in to your account.';
      final ok = await showCarbonConfirm(
        context,
        title: title,
        body: body,
        confirmLabel: isLocal ? 'Remove' : 'Forget',
        danger: true,
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
      _modalOpen = false;
      _restoreFocus();
      _releaseLatchAfterFrame(() => !_modalOpen && !_menuOpen);
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

/// Per-row "New session" affordance. Stateful so we can self-disable while a
/// previous tap's create/start (or project switch) is still in flight —
/// double-tapping would otherwise spawn duplicate sessions.
class _NewSessionButton extends ConsumerStatefulWidget {
  final DrawerEntry entry;

  /// Held true for as long as a tap is in flight. A cold remote open runs for
  /// tens of seconds, and without the latch the busy spinner would hide the
  /// moment the pointer leaves the row. It is also what keeps the failure
  /// toast's `mounted` check true.
  final ValueChanged<bool>? onLatch;

  const _NewSessionButton({super.key, required this.entry, this.onLatch});

  @override
  ConsumerState<_NewSessionButton> createState() => _NewSessionButtonState();
}

class _NewSessionButtonState extends ConsumerState<_NewSessionButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    // Busy keeps the button enabled but inert, so a tap while a cold open is in
    // flight cannot start a second one.
    return CarbonButton.iconOnly(
      icon: const CarbonIcon(CarbonIcons.add),
      size: CarbonButtonSize.extraSmall,
      semanticLabel: 'New session',
      busy: _busy,
      onPressed: () => detached('DrawerEntryRow', 'new session', _onTap),
    );
  }

  Future<void> _onTap() async {
    final onLatch = widget.onLatch;
    setState(() => _busy = true);
    onLatch?.call(true);
    try {
      await _newSessionForEntry();
    } finally {
      if (mounted) setState(() => _busy = false);
      onLatch?.call(false);
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
      // the live `agentDeviceId` it reconnects to), so read it back rather than
      // reusing `entryId`.
      final pid = container.read(selectedRegistrationIdProvider);
      if (pid == null) return;

      // Warm the per-project ProjectSession (transport + services) so the
      // New Session page — and the subsequent startNewSession — find a ready
      // session rather than racing the async factory.
      await container.read(projectSessionProvider(pid).future);
      if (container.read(selectedRegistrationIdProvider) != pid) return;

      // Route to the New Session page with this project preselected (it is the
      // current focus, so enterNewSession reverse-looks-it-up as the target and
      // seeds the agent dropdown from its agent:hello). `retarget` because this
      // row NAMES a project: a draft left over from another one must not keep
      // the target the user just tapped past.
      enterNewSession(container, retarget: true);
    } catch (e) {
      if (mounted) {
        showAbToast(
          context,
          "Couldn't start a new session. ${caughtErrorCopy(e, 'Try again.')}",
        );
      }
    }
  }
}

/// Online/offline mark for a remote machine header. Peek-only
/// ([supervisorStatusProvider] never dials), so a collapsed-but-healthy
/// machine isn't mislabelled: a null status (never connected, so unknown)
/// renders nothing, and the mark appears once the socket is dialed (on expand
/// or refresh).
class _MachineOnlineMark extends ConsumerWidget {
  const _MachineOnlineMark({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflict =
        ref.watch(centralControlConflictProvider(machineUuid)).value ?? false;
    if (conflict) {
      return _livenessCell(
        context,
        child: CarbonButton.iconOnly(
          icon: const CarbonIcon(CarbonIcons.renew),
          kind: CarbonButtonKind.dangerGhost,
          size: CarbonButtonSize.extraSmall,
          semanticLabel: 'Control connection conflict — Retry',
          onPressed: () =>
              ref.read(relayConnectionManagerProvider).peek(machineUuid)?.retry(),
        ),
      );
    }
    final status = ref.watch(supervisorStatusProvider(machineUuid)).value;
    if (status == null) return _livenessCell(context);
    final t = CarbonTheme.of(context);
    // Stated as a switch over the sealed type, so a fifth [SupervisorStatus]
    // has to opt in here rather than inherit a look nothing chose. Only a
    // ladder still climbing pulses: both settled states hold still, `Released`
    // being a deliberate teardown and `Blocked` staying sticky until a typed
    // unblock input clears it.
    final liveness = switch (status) {
      Connected() => DrawerLiveness.connected,
      Climbing() => DrawerLiveness.connecting,
      Blocked() => DrawerLiveness.failed,
      Released() => DrawerLiveness.offline,
    };
    // Colour is this mark's only visual channel, and it is the drawer's sole
    // report that a machine is unreachable, so the ladder's own label carries
    // it to anyone who cannot use hue.
    final (_, label) = connectionDisplayInfo(status);
    return _livenessCell(
      context,
      child: CarbonLivenessDot(
        liveness: liveness,
        size: _dotSize(t),
        semanticLabel: label,
        hollowFill: _transparentFill(t),
      ),
    );
  }
}

/// Aggregate work-status dot for a collapsed machine header: shows only the
/// states that want the user to come and look (attention/error/unread) across
/// ALL projects on [machineUuid]. Hidden when expanded, because the machine's
/// projects are on screen then and their session rows carry the dots, and
/// hidden when status is working/done, keeping idle machine headers clean.
/// `working` is excluded for the same reason `unread` is not: a busy agent will
/// finish on its own, an unread answer stays unread until someone opens it.
///
/// The slot's width is reserved whether or not a dot renders, so an agent
/// asking a question cannot widen the trailing cell and shove the liveness mark
/// off the rail.
class _MachineAggregateDot extends ConsumerWidget {
  const _MachineAggregateDot({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = CarbonTheme.of(context).iconSize;
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(machineUuid);
    if (expanded) return SizedBox(width: width);
    final status = ref.watch(machineWorkStatusProvider(machineUuid));
    if (status == null || !agentWorkStatusNeedsUser(status)) {
      return SizedBox(width: width);
    }
    return SizedBox(
      width: width,
      child: Center(child: _AttentionDot(status: status)),
    );
  }
}

/// The project's latest status carries an error. The row owns the key so
/// widget tests can locate the mark per-project. Tapping it surfaces
/// [message] in a toast, which works on mobile (no hover) where a tooltip
/// would not.
///
/// A bare glyph with a tap, not a button: it sits in the row's content, which
/// is silent to assistive tech and must not carry a touch-sized control that
/// would stretch the row. The message is spoken from the row's own name.
class _ConfigErrorMark extends StatelessWidget {
  const _ConfigErrorMark({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final glyph = CarbonStatusIcon(CarbonStatusKind.error, size: t.iconSize);
    final msg = message;
    if (msg == null || msg.isEmpty) return glyph;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: () => showAbToast(context, msg),
      child: glyph,
    );
  }
}

/// Says an on-demand command is currently running for the project. Purely
/// informational.
class _CommandTag extends StatelessWidget {
  final String commandName;
  const _CommandTag({super.key, required this.commandName});

  @override
  Widget build(BuildContext context) => CarbonTag(
    label: commandName,
    size: CarbonTagSize.small,
    color: CarbonTagColor.blue,
  );
}

/// The header row of one advertised project under an expanded machine row:
/// its name, collapsed by default; a tap toggles its expansion. The host
/// renders the session list beneath it as a sibling. The compound
/// `<uuid>.<projectId>` regId is the key in [expandedDrawerIdsProvider] (its dot
/// keeps it out of the machine-socket keep-alive set, which only counts
/// bare-uuid ids).
class AdvertisedProjectRow extends ConsumerWidget {
  final String machineUuid;
  final AdvertisedProject project;
  const AdvertisedProjectRow({
    super.key,
    required this.machineUuid,
    required this.project,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regId = RemoteProject(
      machineUuid: machineUuid,
      projectId: project.projectId,
    ).registrationId;
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(regId);
    final isWarm = ref.watch(
      projectSessionRegistryProvider.select((open) => open.contains(regId)),
    );
    // No permanent run-state glyph: it made the remote half of the drawer read
    // as busier than the local half for no reason the user could name. The same
    // collapsed-only attention dot a local project shows takes its place.
    final needsUser =
        !expanded && DrawerProjectAggregateDot.needsUser(ref, regId);
    final work = ref.watch(projectWorkStatusProvider(regId));
    final demo = ref.watch(demoModeProvider);
    final label = project.label;
    final name = (label != null && label.isNotEmpty)
        ? label
        : project.projectId;
    return _ProjectRow(
      name: name,
      spokenName: _spokenProjectName(
        name,
        extras: [if (needsUser) workStatusLabel(work)],
      ),
      expanded: expanded,
      warm: isWarm,
      onToggle: () => ref.read(expandedDrawerIdsProvider.notifier).toggle(regId),
      marks: [if (needsUser) DrawerProjectAggregateDot(entryId: regId)],
      // The same order as a local project row, which also ends in a remove
      // menu; this row has none, so Memory (or the + in the demo) owns the rail.
      actions: [
        // Creates a session in THIS project (not the machine): lands on New
        // Session already targeting it, so the user only picks the agent and
        // hits Start.
        CarbonButton.iconOnly(
          icon: const CarbonIcon(CarbonIcons.add),
          size: CarbonButtonSize.extraSmall,
          semanticLabel: 'New session',
          onPressed: () {
            enterNewSessionForRemoteProject(
              ref.container,
              machineUuid: machineUuid,
              project: project,
            );
            closeDrawerIfOverlay(context);
          },
        ),
        if (!demo)
          MemoryProjectButton(
            target: MemoryTarget.machine(machineId: machineUuid),
            projectId: project.projectId,
            projectName: name,
          ),
      ],
    );
  }
}
