// app/lib/widgets/projects_drawer.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_docked_column.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_row_trailing.dart';
import '../design/widgets/ab_tap_target.dart';
import '../models/drawer_entry.dart';
import '../project/project_session_registry.dart'
    show projectSessionRegistryProvider;
import '../models/session_target.dart';
import '../providers/account_agents.dart';
import '../providers/control_plane.dart';
import '../providers/demo_mode.dart';
import '../providers/drawer_entries.dart';
import '../providers/drawer_expansion.dart';
import '../providers/drawer_order.dart';
import '../providers/collapsed_drawer.dart';
import '../providers/new_session_action.dart';
import '../providers/new_session_picker.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../services/control_plane_client.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'ab_status_helpers.dart' show emptyAdvertHint;
import 'account_footer.dart';
import 'drawer_entry_row.dart'
    show
        DrawerEntryRow,
        DrawerProjectAggregateDot,
        DrawerProjectLeading,
        HoverableDrawerRow,
        LocalMachineBand,
        MachineDrawerHeaderRow,
        drawerProjectTitleStyle;
import 'first_run_checklist.dart';
import 'open_folder_button.dart';
import 'session_row.dart';
import 'update_row.dart';

/// Always-visible (desktop) / slide-in (mobile) drawer listing local projects
/// and paired remote agents merged by last-access. Width is fixed at 288px on
/// desktop; on mobile it fills the natural Scaffold drawer width.
class ProjectsDrawer extends ConsumerStatefulWidget {
  const ProjectsDrawer({super.key});

  @override
  ConsumerState<ProjectsDrawer> createState() => _ProjectsDrawerState();
}

class _ProjectsDrawerState extends ConsumerState<ProjectsDrawer> {
  /// Lets the header's refresh BUTTON drive the list's pull-to-refresh
  /// indicator, so the two affordances share their feedback and not just their
  /// handler. Without it the button's only answer to a tap was going dim, on a
  /// refresh whose slowest leg is a network round trip — indistinguishable
  /// from a tap that missed.
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  /// True from the tap until the indicator has finished retracting.
  ///
  /// The button's other in-flight signal — the inventory load — clears the
  /// moment the HTTPS leg returns, which is well before the indicator is done:
  /// `refreshDrawer` still has the control-plane pull to run, and
  /// `RefreshIndicator` then spends [_kIndicatorSettle] scaling out. A tap in
  /// that tail is worse than a stacked fetch: `show()` only short-circuits
  /// while the indicator is snapping or refreshing, and the scale controller
  /// it skips resetting leaves the spinner painting at zero — a full refresh
  /// with no feedback at all, which is the failure this button exists to fix.
  bool _refreshBusy = false;

  /// `RefreshIndicator`'s own dismiss animation (`_kIndicatorScaleDuration`),
  /// which it does not expose. Mirrored rather than read, so the button stays
  /// disabled until the widget is genuinely idle again.
  static const _kIndicatorSettle = Duration(milliseconds: 200);

  Future<void> _refreshFromButton() async {
    if (_refreshBusy) return;
    setState(() => _refreshBusy = true);
    try {
      await _refreshKey.currentState?.show();
      await Future<void>.delayed(_kIndicatorSettle);
    } finally {
      if (mounted) setState(() => _refreshBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Unfiltered by design. The session search lives in the window title bar
    // and aims at the Recent list, which is the complete flat view of sessions;
    // narrowing THIS list by its projects' sessions only hid rows the user was
    // looking straight at.
    final entries = ref.watch(drawerEntriesProvider);

    return MenuBoundsScope(
      child: Container(
        width: 288,
        // Clipped because [AbDockedColumn] never squeezes its header: on a
        // window too short for even that, a truncated sidebar beats chrome
        // bleeding over the workspace beside it.
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: context.antgrid.bgDeep,
          border: Border(
            right: BorderSide(color: context.antgrid.borderDefault),
          ),
        ),
        // Not a Column: on a first run the chrome below the list is ~300px of
        // fixed height, which a short window cannot pay for — and a Flex
        // answers that by asserting, because its non-flex children are laid out
        // unbounded. Here the list yields first and the setup section scrolls
        // inside its own slot, so no height can overflow.
        child: AbDockedColumn(
          // Keeps a strip of the list on screen however short the window gets;
          // otherwise a tall checklist leaves the sidebar showing no projects at
          // all. Borrowed from the token scale as a floor, not a measurement —
          // it answers how much list is worth keeping on screen, not how tall a
          // row is, so it stays independent of the rows' own
          // [AbRowContentFloor] and need never agree with it.
          minBodyExtent: AbTokens.rowHeightLg,
          header: _TopChrome(
            onRefresh: _refreshBusy ? null : _refreshFromButton,
          ),
          body: _Body(entries: entries, refreshKey: _refreshKey),
          // Docked here, not on the New Session canvas: the drawer is the only
          // desktop surface mounted on both routes, and the last setup steps
          // are performed from inside a session.
          dock: const _SetupDock(),
          // Both are permanent affordances, so neither may be scrolled out of
          // reach — the update row in particular stays pending until the app
          // restarts (see update_row.dart). The account footer is declared last
          // so it is the last BUDGETED slot to give up a pixel; only the
          // unbudgeted header outranks it.
          // Neither belongs to a machine-less demo: the footer's account row
          // fetches the user, the subscription and the pricing catalogue, and
          // the update row's only action leaves for the store.
          pinned: ref.watch(demoModeProvider)
              ? const []
              : const [UpdateRow(), _Footer()],
        ),
      ),
    );
  }
}

/// Fixed chrome above the project list. One slot because [AbDockedColumn]
/// budgets per slot and neither of these may be compressed — the New Session
/// button is the drawer's primary action.
///
/// This is the header slot, which is never budgeted at all, so it outranks even
/// the pinned rows: on a panel too short for it the account footer is already
/// gone while both still paint whole, and the drawer's clip is what
/// keeps them off the workspace.
class _TopChrome extends StatelessWidget {
  const _TopChrome({required this.onRefresh});

  /// Null while a refresh the button started is still on screen — see
  /// [_ProjectsDrawerState._refreshBusy].
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _NavActions(),
        _GroupLabel(label: 'PROJECTS', onRefresh: onRefresh),
      ],
    );
  }
}

/// The setup checklist in its docked slot, between the project list and the
/// pinned rows below it.
///
/// Scrollable because this is the slot [AbDockedColumn] compresses once the
/// list is at its floor — a bare section here would only move the overflow one
/// level down. It scrolls only when it must: given room the viewport takes the
/// content's own height, so the docked layout is unchanged at every size that
/// fits.
class _SetupDock extends ConsumerWidget {
  const _SetupDock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The section self-gates to nothing on mobile and once the checklist is
    // done or dismissed, which is most of an install's life. Gating here too
    // keeps a Scrollable (and the ScrollBehavior's Scrollbar) out of every
    // sidebar that will never scroll one.
    if (!desktopSetupSectionVisible(ref)) return const SizedBox.shrink();
    return const SingleChildScrollView(
      // Explicit rather than platform-derived: docked chrome that rubber-bands
      // under a trackpad flick (macOS's default physics) reads as broken.
      physics: ClampingScrollPhysics(),
      // Never the PrimaryScrollController's: the project list beside it is the
      // drawer's scrollable of record.
      primary: false,
      child: FirstRunSetupSection(),
    );
  }
}

/// Mobile: the drawer is a slide-in overlay, so an action that navigates
/// elsewhere must dismiss it or the destination stays hidden behind it. No-op on
/// desktop, where the drawer is always-on chrome rather than a route.
void closeDrawerIfOverlay(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold?.hasDrawer == true && scaffold!.isDrawerOpen) {
    Navigator.of(context).pop();
  }
}

class _NavActions extends ConsumerWidget {
  const _NavActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.drawerGutter,
        AbTokens.drawerGutter,
        AbTokens.space4,
      ),
      child: SizedBox(
        width: double.infinity,
        child: AbButton(
          label: 'New Session',
          color: context.antgrid.accent,
          fontSize: AbTokens.fontBody,
          leading: AbIcon(AbIcons.add, size: 12, color: context.antgrid.accent),
          onTap: () => enterNewSession(ref.container),
        ),
      ),
    );
  }
}

/// The panel title, above every machine band.
///
/// Carries no count. The number it used to show was the length of the top-level
/// entry list, which counts each remote MACHINE as one — while the projects it
/// actually holds are unknown until the row is expanded, and asking would open
/// a control-plane socket per machine at drawer build. Nothing in the drawer
/// counts its own contents any more: the panel is scanned for the one row that
/// needs the user, which is what the attention dots are for.
class _GroupLabel extends ConsumerWidget {
  const _GroupLabel({required this.label, required this.onRefresh});

  /// Raises the list's [RefreshIndicator] — see
  /// [_ProjectsDrawerState._refreshFromButton]. Null while one is still up.
  final Future<void> Function()? onRefresh;

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The button shares [refreshDrawer] with the pull-to-refresh gesture so the
    // two affordances refresh the same things. The in-flight guard keys off the
    // inventory load (the only load-once FutureProvider); local projects and
    // Recent machines are store-reactive. Riverpod preserves the prior value
    // during the reload, so the list never blanks.
    // Demo: the sample project refreshes from nothing, and the watch itself is
    // what would fetch /account/agents. Neither the flag nor the button.
    final demo = ref.watch(demoModeProvider);
    final refreshing = demo
        ? false
        : ref.watch(accountAgentsProvider).isLoading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.space10,
        AbTokens.drawerGutter,
        AbTokens.space6,
      ),
      // A section header's height is its type + padding; the refresh button is
      // inline chrome inside it, not a standalone touch affordance.
      child: AbCompactTapTargets(
        child: Row(
          children: [
            Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (!demo)
              AbIconButton(
                icon: AbIcons.refresh,
                tone: AbIconButtonTone.muted,
                tooltip: 'Refresh',
                // Goes through the indicator rather than calling
                // [refreshDrawer] directly: it runs the SAME handler the pull
                // gesture does and animates the same spinner, so a tap and a
                // pull are one interaction with one piece of feedback.
                //
                // Disabled on either in-flight signal: an inventory fetch (so
                // a double-tap can't stack redundant /account/agents requests)
                // or an indicator the button itself raised.
                onTap: refreshing || onRefresh == null
                    ? null
                    : () => detached(
                        'ProjectsDrawer',
                        'drawer refresh failed',
                        onRefresh!,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends ConsumerWidget {
  const _Footer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const AccountFooter();
  }
}

class _Body extends ConsumerWidget {
  final List<DrawerEntry> entries;

  /// Owned by [_ProjectsDrawerState] so the header's refresh button can show
  /// this indicator too.
  final GlobalKey<RefreshIndicatorState> refreshKey;
  const _Body({required this.entries, required this.refreshKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Demo: the gesture has nothing to pull from, and leaving it wired would
    // put a spinner on a surface that must never reach the network.
    if (ref.watch(demoModeProvider)) return _list(context, ref);
    // Pull-to-refresh wraps every branch (incl. the empty state) so the gesture
    // is available whether or not projects are listed.
    return RefreshIndicator(
      key: refreshKey,
      // The guard belongs HERE, not around a caller's `show()`:
      // `RefreshIndicator` completes the future it hands back with
      // `completer.complete()` from a `whenComplete`, so a rejection never
      // reaches the caller — it escapes on the framework's own discarded
      // future and lands on `PlatformDispatcher.onError` as a fatal crash.
      onRefresh: () async {
        try {
          await refreshDrawer(ref);
        } catch (error, stack) {
          AbLog.error(
            'ProjectsDrawer',
            'drawer refresh failed',
            fields: {'error': '$error', 'stack': '$stack'},
          );
        }
      },
      color: context.antgrid.accent,
      backgroundColor: context.antgrid.bgElevated,
      child: _list(context, ref),
    );
  }

  Widget _list(BuildContext context, WidgetRef ref) {
    if (entries.isEmpty) {
      // Point at the real entry points rather than a nonexistent "[+]". On
      // desktop the New Session canvas (with its "Open local folder" / "Pair
      // remote project" cards) sits right beside this drawer, so steer there;
      // local folders aren't supported on mobile, so name only pairing.
      //
      // A scrollable (not a bare Center) so the pull-to-refresh gesture works
      // with zero rows — overscroll needs something scrollable to grab.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AbTokens.space24),
            child:
                // Mobile has no local folders — this drawer fills from machines
                // on the account, so point there (the New Session canvas
                // carries the full connect steps).
                isMobilePlatform
                ? const AbEmptyState(
                    title: 'No projects yet',
                    subtitle: 'Connect a machine to see its projects here.',
                  )
                // Desktop's real entry point is a local folder; offer it
                // in place instead of describing where else to find it.
                : const AbEmptyState(
                    title: 'No projects yet',
                    subtitle: 'Open a folder to get started.',
                    action: OpenFolderButton(),
                  ),
          ),
        ],
      );
    }
    // The band names ONE machine, so it is emitted once for the whole list —
    // at the first local project, wherever the persisted order happens to put
    // it. Derived from the list rather than from each row's neighbour: an
    // order that interleaves locals with machines (a drag, or a newly opened
    // folder appended after them by `applyDrawerOrder`) would otherwise open a
    // second, identically-labelled "This machine".
    final firstLocal = entries.indexWhere((e) => e.kind == EntryKind.local);
    return ReorderableListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: AbTokens.space4),
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      proxyDecorator: (child, _, _) =>
          Material(color: context.antgrid.bgElevated, child: child),
      onReorderItem: (from, to) {
        final ids = entries.map((e) => e.id).toList(growable: false);
        // The persist call is fire-and-forget by design — the in-memory state
        // updates synchronously and the SharedPreferences write is best-effort.
        unawaited(
          ref
              .read(drawerOrderProvider.notifier)
              .move(currentIds: ids, from: from, to: to),
        );
      },
      itemBuilder: (_, i) => _EntryWithSessions(
        // ValueKey lives on the wrapper so the reorder framework keys the
        // whole Column (entry row + optional SessionsList), not the inner row.
        key: ValueKey(entries[i].id),
        entry: entries[i],
        reorderIndex: i,
        // Attached to the row rather than partitioning the list, so reordering
        // keeps working exactly as it did: drag the first local project and
        // the band simply follows it. A LEGACY per-project remote row
        // (compound id, so `machineUuid` is null) is not local and opens no
        // band — it keeps its own REMOTE chip instead.
        showLocalBand: i == firstLocal,
        // Every band but the first gets a hairline above it; the first already
        // has the PROJECTS label.
        showRule: i > 0,
      ),
    );
  }
}

/// Pull-to-refresh / refresh-button handler for the drawer. Re-fetches the
/// machine inventory (HTTPS) and re-pulls the live project advert for every
/// machine whose control-plane socket is already open (the reaper's alive set —
/// refreshing never force-opens sockets for machines the user isn't viewing).
/// Also re-lists the focused project's sessions (data plane).
///
/// The session re-list is FIRE-AND-FORGET: its reply carries a 15s timeout
/// (`_kPendingReplyTimeout`), so gating the spinner on it would pin the
/// indicator long after the fast inventory + advert pulls returned. It swallows
/// its own errors and updates the UI via the SessionsService stream when the
/// reply lands. Shared by the pull gesture and the PROJECTS refresh button so
/// the two affordances stay in lockstep.
Future<void> refreshDrawer(WidgetRef ref) async {
  // The demo hides both affordances that call this; the guard is here so a
  // third caller cannot reintroduce the inventory fetch by accident.
  if (ref.read(demoModeProvider)) return;
  unawaited(_refreshFocusedSessions(ref));
  await refreshMachineInventoryAndControlPlanes(
    RefreshRef.of(ref),
    ref.read(controlPlaneAliveTargetsProvider),
  );
}

Future<void> _refreshFocusedSessions(WidgetRef ref) async {
  try {
    // Throws synchronously when no project is focused or the session is still
    // resolving — nothing to refresh in that case.
    await ref.read(sessionsServiceProvider).requestList();
  } catch (_) {}
}

/// Renders a project row plus, when this entry is expanded
/// (id absent from [collapsedDrawerIdsProvider]), its sessions tree below it. Expansion is
/// independent of activation: a project can be expanded without being active
/// (it shows cached sessions) and active without being expanded (the user
/// collapsed it manually).
///
/// [reorderIndex] is non-null only when this row is in the
/// [ReorderableListView.builder] branch of `_Body`. When set, the
/// [ReorderableDelayedDragStartListener] wraps ONLY the entry row — never the
/// nested [SessionsList] — so a long-press on a [SessionRow] or the "+ New
/// session" tile cannot initiate a project-reorder drag.
class _EntryWithSessions extends ConsumerWidget {
  final DrawerEntry entry;
  final int? reorderIndex;
  final bool showLocalBand;
  final bool showRule;
  const _EntryWithSessions({
    super.key,
    required this.entry,
    this.reorderIndex,
    this.showLocalBand = false,
    this.showRule = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A remote MACHINE entry (same-account or inventory) defaults to COLLAPSED
    // and tracks its open state in [expandedDrawerIdsProvider] — expanding it is
    // what opens the machine's control-plane socket. A local project (or a
    // legacy per-project row) defaults to EXPANDED and tracks its (rarer)
    // collapse in [collapsedDrawerIdsProvider].
    final machineUuid = entry.machineUuid;
    final expanded = machineUuid != null
        ? ref.watch(expandedDrawerIdsProvider).contains(machineUuid)
        : !ref.watch(collapsedDrawerIdsProvider).contains(entry.id);
    final entryRow = machineUuid != null
        ? MachineDrawerHeaderRow(entry, showRule: showRule)
        : DrawerEntryRow(entry);
    final entryRowWrapped = reorderIndex != null
        ? ReorderableDelayedDragStartListener(
            index: reorderIndex!,
            child: entryRow,
          )
        : entryRow;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLocalBand) LocalMachineBand(showRule: showRule),
        entryRowWrapped,
        if (expanded)
          machineUuid != null
              ? _MachineProjects(machineUuid: machineUuid)
              : SessionsList(projectId: entry.id),
      ],
    );
  }
}

/// Muted, indented one-liner under a machine row — used for the loading,
/// offline, and empty states so the machine subtree always says *something*
/// rather than collapsing to nothing.
///
/// [indent] is the depth of the rows this hint STANDS IN FOR, which is not
/// always the depth of the row above it: under a project it replaces session
/// rows ([AbTokens.drawerSessionIndent]), under a machine band it replaces
/// project rows, which sit at the gutter.
Widget _machineHint(
  BuildContext context,
  String text, {
  double indent = AbTokens.drawerSessionIndent,
}) {
  return Padding(
    padding: EdgeInsets.fromLTRB(
      indent,
      AbTokens.space2,
      AbTokens.drawerGutter,
      AbTokens.space4,
    ),
    child: Text(
      text,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontXs,
        color: context.antgrid.textMuted,
      ),
    ),
  );
}

/// The advertised project tree of a remote machine, fetched lazily once its
/// drawer row is expanded. Watching [controlPlaneStateProvider] opens the
/// machine's control-plane socket — kept alive while the row stays open by the
/// expanded-machine union in [controlPlaneAliveTargetsProvider]; collapsing the
/// row drops it from that set and the reaper closes the socket. An empty/errored
/// FLAG-LESS advert reads as "offline" (an absent control-plane client yields an
/// empty [ControlPlaneState], not an error), matching the New Session picker; an
/// advert carrying the machine-level `remoteAccessEnabled` flag says WHY it is
/// empty (switch off vs genuinely no projects) and is rendered as such.
class _MachineProjects extends ConsumerWidget {
  final String machineUuid;
  const _MachineProjects({required this.machineUuid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(controlPlaneStateProvider(machineUuid));
    // Everything here stands in for the machine's PROJECT rows, which sit at
    // the gutter like a local project — not at session depth.
    return stateAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.fromLTRB(
          AbTokens.drawerGutter,
          AbTokens.space6,
          AbTokens.drawerGutter,
          AbTokens.space6,
        ),
        child: Align(alignment: Alignment.centerLeft, child: AbLoading()),
      ),
      error: (_, _) => _machineHint(
        context,
        'Machine offline',
        indent: AbTokens.drawerGutter,
      ),
      data: (state) {
        final projects = state.projects;
        if (projects.isEmpty) {
          return _machineHint(
            context,
            emptyAdvertHint(state.remoteAccessEnabled),
            indent: AbTokens.drawerGutter,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in projects)
              _AdvertisedProjectRow(machineUuid: machineUuid, project: p),
          ],
        );
      },
    );
  }
}

/// One advertised project under an expanded machine row: name + run-state
/// icon, collapsed by default, expanding to its session list. The compound
/// `<uuid>.<projectId>` regId is the key in [expandedDrawerIdsProvider] (its dot
/// keeps it out of the machine-socket keep-alive set, which only counts
/// bare-uuid ids).
class _AdvertisedProjectRow extends ConsumerStatefulWidget {
  final String machineUuid;
  final AdvertisedProject project;
  const _AdvertisedProjectRow({
    required this.machineUuid,
    required this.project,
  });

  @override
  ConsumerState<_AdvertisedProjectRow> createState() =>
      _AdvertisedProjectRowState();
}

class _AdvertisedProjectRowState extends ConsumerState<_AdvertisedProjectRow> {
  /// Keyboard focus reveals the row's action alongside hover: an affordance
  /// that only a pointer can summon is unreachable by keyboard entirely.
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final regId = RemoteProject(
      machineUuid: widget.machineUuid,
      projectId: widget.project.projectId,
    ).registrationId;
    final expanded = ref.watch(expandedDrawerIdsProvider).contains(regId);
    final isWarm = ref.watch(
      projectSessionRegistryProvider.select((open) => open.contains(regId)),
    );
    final label = widget.project.label;
    final name = (label != null && label.isNotEmpty)
        ? label
        : widget.project.projectId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HoverableDrawerRow(
          builder: (context, hovered, pointerOver) {
            final revealed = hovered || _focused;
            // No permanent run-state glyph: it made the remote half of the
            // drawer read as busier than the local half for no reason the user
            // could name. The same collapsed-only attention dot a local project
            // shows takes its place, built in the same order as
            // `_DrawerEntryTrailing`'s — rollup inboard, action outermost — so
            // the two halves of the drawer are one row grammar down to their
            // metrics.
            final aggregate =
                (!expanded && DrawerProjectAggregateDot.needsUser(ref, regId))
                ? DrawerProjectAggregateDot(entryId: regId)
                : null;
            final newSession = revealed
                // Create a session in THIS project (not the machine): lands on
                // New Session already targeting it — the user only picks the
                // agent and hits Start.
                ? AbIconButton(
                    icon: AbIcons.add,
                    tooltip: 'New session',
                    onTap: _newSessionForProject,
                  )
                : null;
            // The rail cell goes to whichever element is outermost, so the dot
            // inherits it at rest instead of sitting a full cell inboard of
            // every other row's trailing glyph.
            final cells = <Widget?>[];
            if (newSession == null) {
              if (aggregate != null) {
                cells.add(AbRowTrailingCell(child: aggregate));
              }
            } else {
              cells.add(aggregate);
              cells.add(AbRowTrailingCell(child: newSession));
            }
            return AbListRow(
              horizontalPadding: 0,
              density: AbRowDensity.sm,
              contentFloor: AbRowContentFloor.iconButton,
              // No `hoverable`: matches the local project row, which never took
              // it — the fill previews selection, and this row's tap expands.
              // See `DrawerBand` for the rule.
              leading: DrawerProjectLeading(
                expanded: expanded,
                pointerOver: pointerOver,
                warm: isWarm,
              ),
              title: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: drawerProjectTitleStyle(context),
              ),
              trailing: AbRowTrailingCell.kit(cells),
              margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
              onFocusChange: (v) => setState(() => _focused = v),
              onTap: () =>
                  ref.read(expandedDrawerIdsProvider.notifier).toggle(regId),
            );
          },
        ),
        if (expanded) _ProjectSessions(regId: regId),
      ],
    );
  }

  void _newSessionForProject() {
    enterNewSessionForRemoteProject(
      ref.container,
      machineUuid: widget.machineUuid,
      project: widget.project,
    );
    closeDrawerIfOverlay(context);
  }
}

/// Triggers the drawer's per-project session-list peek
/// ([drawerProjectSessionsProvider]) and renders whatever
/// [sessionsForEntryProvider] holds (cached first, then the freshly-fetched list
/// once it lands). Falls back to a hint while the fetch is in flight or yields
/// nothing. The peek is read-only — it never starts the project.
class _ProjectSessions extends ConsumerWidget {
  final String regId;
  const _ProjectSessions({required this.regId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fetch = ref.watch(drawerProjectSessionsProvider(regId));
    final sessions = ref
        .watch(sessionsForEntryProvider(regId))
        .where((s) => !s.archived)
        .toList(growable: false);
    if (sessions.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in sessions)
            SessionRow(key: ValueKey(s.id), entryId: regId, session: s),
        ],
      );
    }
    return fetch.when(
      loading: () => _machineHint(context, 'Loading sessions…'),
      // A control-plane error (NOT_ALLOWED / timeout) is recoverable — make it a
      // tap to re-run the peek rather than a dead end.
      error: (_, _) => _RetryHint(
        text: 'Could not load sessions — tap to retry.',
        onTap: () => ref.invalidate(drawerProjectSessionsProvider(regId)),
      ),
      data: (_) => _machineHint(context, 'No sessions yet.'),
    );
  }
}

/// Tappable variant of [_machineHint] for a recoverable error under a project
/// row. Plain [GestureDetector] (no Material ripple/ink) per the design rules.
class _RetryHint extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _RetryHint({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _machineHint(context, text),
    );
  }
}

/// Branches on whether `projectId` matches the currently-live project (active
/// local folder selection OR connected remote agent): see
/// [sessionsForEntryProvider] for the live-or-cached selection.
///
/// Tapping a session row in a non-live panel switches projects via
/// [activateDrawerEntryById] and carries the desired session id through
/// [pendingActiveSessionIdProvider].
class SessionsList extends ConsumerWidget {
  final String projectId;
  const SessionsList({super.key, required this.projectId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref
        .watch(sessionsForEntryProvider(projectId))
        .where((s) => !s.archived)
        .toList(growable: false);
    // No wrapper Padding — session rows own their own gutter.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in sessions)
          SessionRow(key: ValueKey(s.id), entryId: projectId, session: s),
      ],
    );
  }
}
