// app/lib/widgets/projects_drawer.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_brand_mark.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_tap_target.dart';
import '../models/drawer_entry.dart';
import '../models/session_target.dart';
import '../providers/account_agents.dart';
import '../providers/control_plane.dart';
import '../providers/drawer_entries.dart';
import '../providers/drawer_expansion.dart';
import '../providers/drawer_order.dart';
import '../providers/collapsed_drawer.dart';
import '../providers/new_session_action.dart';
import '../providers/new_session_picker.dart';
import '../providers/project_work_status.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../services/control_plane_client.dart';
import '../utils/platform_utils.dart';
import 'account_footer.dart';
import 'agent_work_status_dot.dart';
import 'drawer_entry_row.dart' show DrawerEntryRow, MachineDrawerHeaderRow;
import 'session_row.dart';
import 'update_row.dart';

/// Always-visible (desktop) / slide-in (mobile) drawer listing local projects
/// and paired remote agents merged by last-access. Width is fixed at 288px on
/// desktop; on mobile it fills the natural Scaffold drawer width.
class ProjectsDrawer extends ConsumerStatefulWidget {
  const ProjectsDrawer({super.key, this.searchFocusNode});
  final FocusNode? searchFocusNode;

  @override
  ConsumerState<ProjectsDrawer> createState() => _ProjectsDrawerState();
}

class _ProjectsDrawerState extends ConsumerState<ProjectsDrawer> {
  late final TextEditingController _searchController;
  // Only created when the parent didn't pass one in. Skipping the allocation
  // when WorkspaceShell owns the focus node (the common case).
  FocusNode? _ownedFocusNode;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(drawerFilterProvider),
    );
    if (widget.searchFocusNode == null) {
      _ownedFocusNode = FocusNode();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  FocusNode get _focusNode => widget.searchFocusNode ?? _ownedFocusNode!;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(drawerEntriesProvider);
    final filter = ref.watch(drawerFilterProvider);
    final filtered = filterDrawerEntries(entries, filter);

    return MenuBoundsScope(
      child: Container(
        width: 288,
        decoration: BoxDecoration(
          color: context.antgrid.bgDeep,
          border: Border(
            right: BorderSide(color: context.antgrid.borderDefault),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            const _NavActions(),
            _GroupLabel(label: 'PROJECTS', count: filtered.length),
            _SearchField(
              controller: _searchController,
              focusNode: _focusNode,
              onChanged: (q) => ref.read(drawerFilterProvider.notifier).set(q),
              onClear: () {
                _searchController.clear();
                ref.read(drawerFilterProvider.notifier).set('');
              },
            ),
            Expanded(
              child: _Body(entries: filtered, hasFilter: filter.isNotEmpty),
            ),
            const UpdateRow(),
            const _Footer(),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    // Brand mark is mobile-only; desktop drops the header entirely.
    if (!isMobilePlatform) return const SizedBox.shrink();
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.drawerGutter),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: const Row(children: [AbBrandMark()]),
    );
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

class _GroupLabel extends ConsumerWidget {
  const _GroupLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The button shares [refreshDrawer] with the pull-to-refresh gesture so the
    // two affordances refresh the same things. The in-flight guard keys off the
    // inventory load (the only load-once FutureProvider); local projects and
    // QR-paired recents are store-reactive. Riverpod preserves the prior value
    // during the reload, so the list never blanks.
    final refreshing = ref.watch(accountAgentsProvider).isLoading;
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
            const SizedBox(width: AbTokens.space6),
            Text(
              '· $count',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
            const Spacer(),
            AbIconButton(
              icon: AbIcons.refresh,
              tone: AbIconButtonTone.muted,
              tooltip: 'Refresh',
              // Disabled while an inventory fetch is in flight so a double-tap
              // can't stack redundant /account/agents requests.
              onTap: refreshing ? null : () => refreshDrawer(ref),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    // Magnifier glyph is field chrome, not part of the drawer row-icon
    // column — left at the default 24px slot. Vertical gap to the next
    // row lives on `_NavActions.top` only.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.space8,
        AbTokens.drawerGutter,
        0,
      ),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClear},
        child: AbSearchField(
          controller: controller,
          focusNode: focusNode,
          hint: 'filter…',
          height: AbTokens.rowHeightXs,
          debounce: null,
          onChanged: onChanged,
          onClear: onClear,
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
  final bool hasFilter;
  const _Body({required this.entries, required this.hasFilter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pull-to-refresh wraps every branch (incl. the empty state) so the gesture
    // is available whether or not projects are listed.
    return RefreshIndicator(
      onRefresh: () => refreshDrawer(ref),
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
      final String message;
      if (hasFilter) {
        message = 'No matches.';
      } else {
        message = 'No projects yet.';
      }
      // A scrollable (not a bare Center) so the pull-to-refresh gesture works
      // with zero rows — overscroll needs something scrollable to grab.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(AbTokens.space16),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
          ),
        ],
      );
    }
    // While the search filter is active, indices in `entries` no longer match
    // the unfiltered list — fall back to a plain list so a long-press can't
    // commit a nonsensical reorder.
    if (hasFilter) {
      return ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: AbTokens.space4),
        itemCount: entries.length,
        itemBuilder: (_, i) => _EntryWithSessions(entry: entries[i]),
      );
    }
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
  const _EntryWithSessions({super.key, required this.entry, this.reorderIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A remote MACHINE entry (same-account or inventory) defaults to COLLAPSED
    // and tracks its open state in [expandedDrawerIdsProvider] — expanding it is
    // what opens the machine's control-plane socket. A local project or legacy
    // QR per-project entry defaults to EXPANDED and tracks its (rarer) collapse
    // in [collapsedDrawerIdsProvider].
    final machineUuid = entry.machineUuid;
    final expanded = machineUuid != null
        ? ref.watch(expandedDrawerIdsProvider).contains(machineUuid)
        : !ref.watch(collapsedDrawerIdsProvider).contains(entry.id);
    final entryRow = machineUuid != null
        ? MachineDrawerHeaderRow(entry)
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
Widget _machineHint(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space24,
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
/// advert reads as "offline" (an absent control-plane client yields an empty
/// [ControlPlaneState], not an error), matching the New Session picker.
class _MachineProjects extends ConsumerWidget {
  final String machineUuid;
  const _MachineProjects({required this.machineUuid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(controlPlaneStateProvider(machineUuid));
    return stateAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.fromLTRB(
          AbTokens.space24,
          AbTokens.space6,
          AbTokens.drawerGutter,
          AbTokens.space6,
        ),
        child: const Align(alignment: Alignment.centerLeft, child: AbLoading()),
      ),
      error: (_, _) => _machineHint(context, 'Machine offline.'),
      data: (state) {
        final projects = state.projects;
        if (projects.isEmpty) {
          return _machineHint(context, 'Offline — no projects advertised.');
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
class _AdvertisedProjectRow extends ConsumerWidget {
  final String machineUuid;
  final AdvertisedProject project;
  const _AdvertisedProjectRow({
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
    final workStatus = ref.watch(projectWorkStatusProvider(regId));
    final t = context.antgrid;
    final name = (project.label != null && project.label!.isNotEmpty)
        ? project.label!
        : project.projectId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.drawerGutter,
          ),
          child: AbListRow(
            horizontalPadding: 0,
            density: AbRowDensity.sm,
            hoverable: true,
            leading: SizedBox(
              width: AbTokens.drawerLeadingSlot,
              height: AbTokens.drawerLeadingSlot,
              child: Center(
                child: AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: AbIcon(
                    AbIcons.chevronRight,
                    size: 10,
                    color: t.textMuted,
                  ),
                ),
              ),
            ),
            title: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: t.textSecondary,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AbTokens.space4,
              children: [
                if (workStatus != AgentWorkStatus.done)
                  AgentWorkStatusDot(
                    key: ValueKey('project-status-dot-$regId'),
                    status: workStatus,
                  ),
                // Create a session in THIS project (not the machine): lands on
                // New Session already targeting it — the user only picks the
                // agent and hits Start.
                AbIconButton(
                  icon: AbIcons.add,
                  tooltip: 'New session',
                  onTap: () => _newSessionForProject(context, ref),
                ),
                _ProjectRunStateIcon(running: project.running),
              ],
            ),
            margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
            onTap: () =>
                ref.read(expandedDrawerIdsProvider.notifier).toggle(regId),
          ),
        ),
        if (expanded) _ProjectSessions(regId: regId),
      ],
    );
  }

  void _newSessionForProject(BuildContext context, WidgetRef ref) {
    enterNewSessionForRemoteProject(
      ref.container,
      machineUuid: machineUuid,
      project: project,
    );
    // Mobile: the drawer is a slide-in overlay — close it so the New Session
    // page is visible. No-op on desktop (drawer is always-on, not a route).
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.hasDrawer == true && scaffold!.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }
}

class _ProjectRunStateIcon extends StatelessWidget {
  const _ProjectRunStateIcon({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    return Tooltip(
      message: running ? 'Running' : 'Stopped',
      child: SizedBox(
        width: AbTokens.drawerLeadingSlot,
        height: AbTokens.drawerLeadingSlot,
        child: Center(
          child: AbIcon(
            running ? AbIcons.start : AbIcons.stop,
            size: 10,
            color: running ? t.statusRunning : t.textMuted,
          ),
        ),
      ),
    );
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
