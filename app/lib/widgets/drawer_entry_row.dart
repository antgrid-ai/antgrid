// app/lib/widgets/drawer_entry_row.dart
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/relay_mechanisms.dart' show ConnectionBlockedException;
import '../connection/supervisor_state.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_row_trailing.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/drawer_entry.dart';
import '../launcher/host_controller.dart' show HostPhase;
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../util/device_id.dart';
import '../project/limits.dart';
import '../project/perf_recorder.dart';
import '../project/project_session_registry.dart';
import '../project/project_status.dart';
import '../providers/agent_transport.dart';
import '../providers/relay_connection.dart';
import '../providers/cached_sessions.dart';
import '../providers/demo_mode.dart';
import '../providers/drawer_entries.dart';
import '../providers/collapsed_drawer.dart';
import '../providers/drawer_expansion.dart';
import '../providers/host_status.dart';
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
import '../providers/sessions.dart';
import '../providers/supervisor_status.dart';
import '../screens/upgrade_screen.dart';
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

/// Section BAND for a remote machine in the drawer — the same visual class as
/// the `PROJECTS` label above it, not a tree node.
///
/// A machine is a container of projects, not a project, and treating it as a
/// third level of tree cost an indent step that every session name underneath
/// then paid for out of a 288px panel. As a band it costs nothing: the projects
/// below it sit at [AbTokens.drawerGutter], exactly where a LOCAL project sits,
/// which is what lets one project row serve both.
///
/// Carries no `REMOTE` chip. Remote is encoded by which band a project is
/// under — the chip was approximating that, and repeating it on the band that
/// already names the machine says nothing.
///
/// Stateful for the two reveal bits a pointer cannot supply: keyboard focus,
/// and the latch a confirm dialog holds while it is up.
class MachineDrawerHeaderRow extends ConsumerStatefulWidget {
  final DrawerEntry entry;

  /// Hairline above, separating this machine's block from whatever precedes
  /// it. False for the first band in the drawer, which already has the
  /// `PROJECTS` label above it.
  final bool showRule;

  const MachineDrawerHeaderRow(this.entry, {super.key, this.showRule = true});

  @override
  ConsumerState<MachineDrawerHeaderRow> createState() =>
      _MachineDrawerHeaderRowState();
}

class _MachineDrawerHeaderRowState
    extends ConsumerState<MachineDrawerHeaderRow> {
  bool _focused = false;
  bool _latched = false;

  void _setLatched(bool v) {
    if (!mounted || _latched == v) return;
    setState(() => _latched = v);
  }

  void _setFocused(bool v) {
    if (!mounted || _focused == v) return;
    setState(() => _focused = v);
  }

  @override
  Widget build(BuildContext context) {
    perfRecorder.noteDrawerRebuild();
    final entry = widget.entry;
    final machineUuid = entry.machineUuid!;
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(machineUuid);
    final offersRemove = _RemoveButton.offersFor(ref, entry);

    return HoverableDrawerRow(
      above: widget.showRule ? const DrawerBandRule() : null,
      builder: (context, hovered, _) {
        final revealed = hovered || _focused || _latched;
        return DrawerBand(
          label: entry.displayName,
          // Kept on the band, unlike the local one: expanding a machine is what
          // opens its control-plane socket, so there is something to disclose.
          expanded: expanded,
          // A band's liveness dot lives at the panel edge permanently, so the
          // action shares its cell rather than claiming one of its own: a
          // second cell would push the trash a slot inboard of every other
          // row's, and collapsing the action would slide the dot on
          // pointer-enter. [_DrawerEntryTrailing] emits no actions here for the
          // same reason — two owners of one cell is a fight.
          trailing: AbRowTrailingCell.kit([
            _DrawerEntryTrailing(
              entry: entry,
              revealed: revealed,
              showRemoteChip: false,
              hostsActions: false,
            ),
            _MachineAggregateDot(machineUuid: machineUuid),
            if (offersRemove)
              AbRowTrailingSwap(
                revealed: revealed,
                resting: _MachineOnlineDot(machineUuid: machineUuid),
                action: _RemoveButton(entry: entry, onLatch: _setLatched),
              )
            else
              AbRowTrailingCell(
                child: _MachineOnlineDot(machineUuid: machineUuid),
              ),
          ]),
          onFocusChange: _setFocused,
          onTap: () =>
              ref.read(expandedDrawerIdsProvider.notifier).toggle(machineUuid),
        );
      },
    );
  }
}

/// The band above THIS machine's local projects.
///
/// Exists so a local project and a remote one are the same row at the same
/// indent under the same kind of header — the drawer's two halves used to
/// diverge in leading glyph, trailing kit and depth all at once. It also gives
/// the local bridge host the only status surface it has in the drawer.
///
/// Deliberately NOT tappable, and so it carries no chevron: a machine band
/// discloses a control-plane fetch, while every local project is already
/// listed below this one. A chevron here would promise a load that does not
/// exist.
class LocalMachineBand extends ConsumerWidget {
  const LocalMachineBand({super.key, this.showRule = true});

  final bool showRule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its own gutter: this is the one band with no [HoverableDrawerRow]
    // around it to supply one (nothing here is hover-reactive), and without it
    // the label sits flush against the panel edge while every other band is
    // inset.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.drawerGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showRule) const DrawerBandRule(),
          DrawerBand(
            label: 'This machine',
            // No host dot under the demo: there is no bridge behind the sample
            // project, and [hostStatusProvider] answers for the REAL machine — on
            // a desktop that opened a project earlier in the session that is a
            // live green dot pinned to a project it has nothing to do with. Every
            // other real-source surface in this drawer is gated the same way.
            // The empty cell stays, so the demo band's title ellipsizes where
            // the real one's does instead of running a cell further right.
            trailing: AbRowTrailingCell(
              child: ref.watch(demoModeProvider) ? null : const _LocalHostDot(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The hairline above a machine band, separating its block from whatever
/// precedes it.
///
/// A SIBLING above the band rather than a wrapper around it: the ~13px this and
/// its clearance occupy would otherwise sit inside the band's [MouseRegion], so
/// the empty strip above a band would take the click cursor while accepting no
/// click, and would pop the band's hover-revealed trash out of dead space.
/// Being const also keeps it out of the hover rebuild.
class DrawerBandRule extends StatelessWidget {
  const DrawerBandRule({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: AbTokens.space8, bottom: AbTokens.space4),
    child: AbSeparator.horizontal(),
  );
}

/// Bridge-host liveness for [LocalMachineBand], mapped from [HostPhase].
///
/// `idle` and `stopped` render NOTHING rather than a grey dot: neither is a
/// fault — the host is spawned on demand, so before the first project is
/// opened there is simply nothing to report, and an indicator there reads as
/// "your machine is offline" on a machine the user is sitting at.
class _LocalHostDot extends ConsumerWidget {
  const _LocalHostDot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(hostStatusProvider).value?.phase;
    final (tone, style, pulse) = switch (phase) {
      HostPhase.up => (AbStatusTone.success, AbDotStyle.filled, false),
      HostPhase.starting ||
      HostPhase.restarting => (AbStatusTone.warning, AbDotStyle.hollow, true),
      HostPhase.failed => (AbStatusTone.danger, AbDotStyle.filled, false),
      _ => (null, AbDotStyle.filled, false),
    };
    if (tone == null) return const SizedBox.shrink();
    return AbStatusDot(tone: tone, style: style, pulse: pulse);
  }
}

/// One INNER status-dot cell in a band's trailing kit.
///
/// The width is reserved whether or not a dot renders, so a socket resolving or
/// an agent asking a question cannot widen this cell and shove the terminal
/// [AbRowTrailingCell] outboard of the column it shares with every other row.
///
/// The reserved width is a floor, not a cap: every dot here is [AbDotSize.sm]
/// today, and a tight box would silently paint a larger one as a squashed
/// circle in an off-centre cell rather than overflow where it can be seen.
class _BandDotSlot extends StatelessWidget {
  const _BandDotSlot({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: AbTokens.dotSizeSm),
    child: child,
  );
}

/// One band in the drawer: a small muted section label with an optional
/// disclosure chevron and trailing status kit.
///
/// The label keeps the casing it was given. A band names a MACHINE, and a
/// machine name is the user's own noun — upper-casing it the way the literal
/// `PROJECTS` label above is upper-cased turns `RadhaAI` into `RADHAAI`. Size,
/// weight and colour are what make it read as a band; the case is not.
///
/// No leading slot at all — that is the whole point of a band. Its label sits
/// at the gutter, level with the `PROJECTS` label, so nothing beneath it reads
/// as indented under it.
class DrawerBand extends StatelessWidget {
  const DrawerBand({
    super.key,
    required this.label,
    this.trailing,
    this.expanded,
    this.onTap,
    this.onFocusChange,
  });

  final String label;
  final Widget? trailing;

  /// Non-null draws a disclosure chevron after the label.
  final bool? expanded;
  final VoidCallback? onTap;

  /// How a band learns it is reachable by keyboard, so a hover-revealed action
  /// can be revealed by focus too.
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    return AbListRow(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: t.textMuted,
                letterSpacing: 0.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (expanded != null) ...[
            const SizedBox(width: AbTokens.space4),
            AbDisclosureChevron(expanded: expanded!),
          ],
        ],
      ),
      trailing: trailing,
      density: AbRowDensity.sm,
      horizontalPadding: 0,
      // On the band rather than on [MachineDrawerHeaderRow], so the local band
      // — which reveals nothing and would otherwise sit shorter — measures the
      // same as a machine band beside it.
      contentFloor: AbRowContentFloor.iconButton,
      // Bands sit in a run of rows that all clear each other by this much; a
      // band with no rule above it has nothing else keeping it off them.
      margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
      // No `hoverable`: a band is a section HEADING, and the project rows it
      // contains take no fill — a heading that lit under the pointer would be
      // the loudest surface in its own section. The chevron is the affordance
      // instead. Rows that DO fill (a session row, a file-tree row) sit in a
      // flat run where the fill just tracks the pointer, so it ranks nothing
      // above its neighbours.
      onTap: onTap,
      onFocusChange: onFocusChange,
    );
  }
}

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

class _DrawerEntryRowState extends ConsumerState<DrawerEntryRow> {
  Timer? _prefetchTimer;
  bool _focused = false;
  bool _latched = false;

  void _setLatched(bool v) {
    if (!mounted || _latched == v) return;
    setState(() => _latched = v);
  }

  void _setFocused(bool v) {
    if (!mounted || _focused == v) return;
    setState(() => _focused = v);
  }

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

    return HoverableDrawerRow(
      onHoverStart: _startPrefetch,
      onHoverEnd: _cancelPrefetch,
      builder: (context, hovered, pointerOver) => AbListRow(
        // Folder by default; chevron under the pointer. Both sit in the same
        // pinned slot so the glyph swap doesn't shift the title.
        //
        // Keyed on the POINTER bit, not the affordance one: the affordance bit
        // is true for the whole life of a touch row, which left every phone
        // showing a chevron and never the folder.
        leading: DrawerProjectLeading(
          expanded: expanded,
          pointerOver: pointerOver,
          warm: isWarm,
        ),
        title: Text(entry.displayName, style: drawerProjectTitleStyle(context)),
        trailing: _DrawerEntryTrailing(
          entry: entry,
          revealed: hovered || _focused || _latched,
          expanded: expanded,
          onLatch: _setLatched,
        ),
        density: AbRowDensity.sm,
        horizontalPadding: 0, // gutter lives on the outer Padding
        contentFloor: AbRowContentFloor.iconButton,
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        onFocusChange: _setFocused,
        onTap: () => machineUuid != null
            ? ref.read(expandedDrawerIdsProvider.notifier).toggle(machineUuid)
            : ref.read(collapsedDrawerIdsProvider.notifier).toggle(entry.id),
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

/// Right-hand affordances of a drawer row: config error, running command,
/// collapsed-only work rollup, REMOTE chip, and the hover actions.
///
/// The work-status dot is COLLAPSED-ONLY. Expanded, work status belongs to the
/// SESSION rows nested under the row, and a rollup beside them only restated
/// whichever session was loudest — see [DrawerProjectAggregateDot], which owns
/// the rule. A machine band answers the same question through
/// [_MachineAggregateDot] instead.
class _DrawerEntryTrailing extends ConsumerWidget {
  const _DrawerEntryTrailing({
    required this.entry,
    required this.revealed,
    this.expanded,
    this.showRemoteChip = true,
    this.hostsActions = true,
    this.onLatch,
  });

  final DrawerEntry entry;

  /// Hover, keyboard focus, or a confirm dialog this row's own trash has open.
  final bool revealed;

  /// Non-null on a PROJECT row, which shows a rollup of its sub-tree while
  /// collapsed. Null on a machine band, which has [_MachineAggregateDot].
  final bool? expanded;

  /// False on a machine band: the band names the machine, so a chip repeating
  /// that it is remote adds nothing.
  final bool showRemoteChip;

  /// False on a machine band, whose [AbRowTrailingSwap] owns the actions. Two
  /// owners of one terminal cell would each claim to be outermost.
  final bool hostsActions;

  /// Held true while a revealed action is still working — the trash's confirm
  /// dialog, the plus's create/start — so the row it was revealed from does not
  /// collapse out from under it, taking the button's own in-flight state with
  /// it.
  final ValueChanged<bool>? onLatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(projectStatusProvider(entry.id));
    final status = statusAsync.value ?? const ProjectStatus.empty();

    final actions = hostsActions && revealed;
    // Asked unconditionally, ahead of `actions`: behind the `&&` the watch it
    // performs would be retired every time the row un-reveals and re-added on
    // the next hover, and `MachineDrawerHeaderRow` already asks it that way —
    // one predicate must not have two subscription lifetimes.
    final offersRemove = _RemoveButton.offersFor(ref, entry) && actions;
    // No per-machine "New session" +: a machine is a container, not a project,
    // so a session must name a project. The + lives on each advertised project
    // row instead (see `_AdvertisedProjectRow`).
    final offersNewSession = actions && entry.machineUuid == null;

    final cells = <Widget>[
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
      // A collapsed project still says whether something inside it needs the
      // user — that is a call to action, and the sessions that would carry it
      // are off screen. It does NOT say how many sessions it holds: a count is
      // a number to read rather than a state to notice, and the drawer is
      // scanned.
      if (expanded == false &&
          DrawerProjectAggregateDot.needsUser(ref, entry.id))
        DrawerProjectAggregateDot(entryId: entry.id),
      if (showRemoteChip && entry.kind == EntryKind.remote)
        AbChip.system(label: 'REMOTE', color: context.antgrid.accent),
    ];

    // Actions outermost, and whatever ends up last carries the cell: the rail
    // is a position in the row, not a property of any one glyph.
    if (offersRemove || offersNewSession) {
      if (offersNewSession) {
        final plus = _NewSessionButton(entry: entry, onLatch: onLatch);
        cells.add(offersRemove ? plus : AbRowTrailingCell(child: plus));
      }
      if (offersRemove) {
        cells.add(
          AbRowTrailingCell(
            child: _RemoveButton(entry: entry, onLatch: onLatch),
          ),
        );
      }
    } else if (hostsActions && cells.isNotEmpty) {
      // Only when this kit IS the row's outermost element. On a machine band it
      // is nested inside one, and claiming a rail cell there would centre an
      // 8px dot in a full button footprint in the MIDDLE of the band's kit.
      cells.last = AbRowTrailingCell(child: cells.last);
    }

    return AbRowTrailingCell.kit(cells, ownsColumn: hostsActions) ??
        const SizedBox.shrink();
  }
}

/// Aggregate work-status dot for a COLLAPSED project row, local or
/// advertised-remote alike: the same narrow call-to-action set
/// [_MachineAggregateDot] shows, for the same reason.
///
/// The rule that drawer project rows carry no dot is about the EXPANDED case —
/// a rollup sitting beside the session rows it summarises only restated
/// whichever of them was loudest. Collapsed, those rows are not on screen, and
/// a session that needs the user has no other way to say so.
class DrawerProjectAggregateDot extends ConsumerWidget {
  const DrawerProjectAggregateDot({super.key, required this.entryId});

  final String entryId;

  /// Whether [entryId] has anything to say. The caller asks BEFORE building the
  /// dot, because a trailing kit that drops absent children has to know they
  /// are absent — a widget that shrinks itself away still occupies a slot and
  /// its gap.
  static bool needsUser(WidgetRef ref, String entryId) =>
      agentWorkStatusNeedsUser(ref.watch(projectWorkStatusProvider(entryId)));

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      AgentWorkStatusDot(status: ref.watch(projectWorkStatusProvider(entryId)));
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

  /// Held true while the confirm dialog is up. The row that revealed this
  /// button collapses on pointer-exit, and the pointer leaves it the moment the
  /// modal opens — without the latch the trash unmounts under its own dialog.
  final ValueChanged<bool>? onLatch;

  const _RemoveButton({required this.entry, this.onLatch});

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
  ConnectionBlockedException(reason: final r) => switch (r) {
    BlockReason.licenseExpired =>
      'Connect failed: this machine needs an active plan or a sign-in.',
    BlockReason.agentOffline => 'Connect failed: that machine is offline.',
    BlockReason.deviceRevoked =>
      "Connect failed: this device's access was revoked.",
    BlockReason.sessionTakenOver =>
      'Connect failed: another device took over this machine.',
    BlockReason.superseded =>
      'Connect failed: a newer connection replaced this one.',
    BlockReason.handshakeFailing =>
      'Connect failed: could not verify that machine.',
  },
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
      showAbSnackBar(context, connectFailureMessage(e));
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
  if (ref.read(agentReachabilityProvider) != AgentReachability.offline) {
    return true;
  }
  // `offline` is reachable ONLY from a Blocked(agentOffline) ladder, so the
  // transport element is already settled in an error that `noProviderRetry`
  // guarantees Riverpod will never re-run: awaiting `.future` alone replays the
  // original exception without dialling anything. BOTH halves are required, for
  // the reasons `MachineConnectionNotifier.retryAgentConnection` sets out.
  ref
      .read(relayConnectionManagerProvider)
      .peek(registrationId)
      ?.supervisor
      ?.retry();
  ref.invalidate(agentTransportForProvider(registrationId));
  try {
    // Null is a machine no source can name coordinates for (dropped from the
    // inventory, never in the reconnect list). Reporting that as online sends
    // the caller into a warm-up that can only time out in silence.
    if (await ref.read(agentTransportForProvider(registrationId).future) ==
        null) {
      if (context.mounted) {
        showAbSnackBar(context, 'That machine is no longer reachable.');
      }
      return false;
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showAbSnackBar(context, connectFailureMessage(e));
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
    // (warm transport), refocus it as a remote target — nothing to dial.
    if (_focusOpenRemoteProject(ref, entryId)) return true;
    // A cold (advertised-but-not-warm) project still needs its machine dialled,
    // then promotion and a data-plane socket, before it can be focused —
    // `_focusOpenRemoteProject` only refocuses one that is already warm.
    return _openColdRemoteProject(context, ref, entryId);
  }

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
      return false;
    }
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
      // inventory when the E2E handshake lands.
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

  /// Held true for as long as a tap is in flight. The row that revealed this
  /// button collapses on pointer-exit, and a cold remote open runs for tens of
  /// seconds — without the latch the button unmounts mid-activation, taking
  /// [_NewSessionButtonState._busy] with it, so a re-hover and a second tap
  /// launch a concurrent one. It is also what keeps the failure snackbar's
  /// `mounted` check true.
  final ValueChanged<bool>? onLatch;

  const _NewSessionButton({required this.entry, this.onLatch});

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
    final (tone, label) = connectionDisplayInfo(status);
    final online = status is Connected;
    // Colour is this dot's only channel, and it is the drawer's sole report
    // that a machine is unreachable — so the ladder's own label carries it to
    // anyone who cannot use hue.
    return Semantics(
      label: label,
      child: AbStatusDot(
        tone: tone,
        style: online ? AbDotStyle.filled : AbDotStyle.hollow,
        // Pulse only while the ladder is still climbing. Stated as a
        // whitelist over the sealed type, so a fifth [SupervisorStatus] has
        // to opt in here rather than inherit an animation nothing stops: both
        // settled states must hold still, `Released` being a deliberate
        // teardown and `Blocked` staying sticky until a typed unblock input
        // clears it.
        pulse: status is Climbing,
      ),
    );
  }
}

/// Aggregate work-status dot for a collapsed machine header: shows only the
/// states that want the user to come and look (attention/error/unread) across
/// ALL projects on [machineUuid]. Hidden when expanded — the machine's projects
/// are on screen then, and their session rows carry the dots — and hidden when
/// status is working/done, keeping idle machine headers clean. `working` is
/// excluded for the same reason `unread` is not: a busy agent will finish on its
/// own, an unread answer stays unread until someone opens it.
class _MachineAggregateDot extends ConsumerWidget {
  const _MachineAggregateDot({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(machineUuid);
    if (expanded) return const _BandDotSlot();
    final status = ref.watch(machineWorkStatusProvider(machineUuid));
    if (status == null || !agentWorkStatusNeedsUser(status)) {
      return const _BandDotSlot();
    }
    return _BandDotSlot(child: AgentWorkStatusDot(status: status));
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
