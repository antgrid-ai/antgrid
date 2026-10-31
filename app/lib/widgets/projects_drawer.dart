// app/lib/widgets/projects_drawer.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_docked_column.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_tap_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/account_agents.dart';
import '../providers/control_plane.dart';
import '../providers/demo_mode.dart';
import '../providers/new_session_picker.dart' show enterNewSession;
import '../providers/project_index.dart';
import '../providers/project_panel.dart';
import '../providers/providers.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'account_footer.dart';
import 'first_run_checklist.dart';
import 'machine_scope_menu.dart';
import 'open_folder_button.dart';
import 'project_sidebar.dart';
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
          // all. Borrowed from the token scale as a floor rather than measured
          // off a row — it answers how much list is worth keeping, not how tall
          // any one row is.
          //
          // Scaled all the same, because the rows it holds room for are: a band
          // floors on [AbIconButton.boxExtent], so above UI Size ~1.15 a fixed
          // 44 falls short of the FIRST row and the strip stops containing a
          // whole one. The dock pays for it, and the dock scrolls.
          minBodyExtent: MediaQuery.textScalerOf(
            context,
          ).scale(AbTokens.rowHeightLg),
          header: const _TopChrome(),
          body: _Body(
            refreshKey: _refreshKey,
            onRefresh: _refreshBusy ? null : _refreshFromButton,
          ),
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
  const _TopChrome();

  @override
  Widget build(BuildContext context) {
    // The scope switcher sits above everything it filters — Needs you and the
    // project list below are both answers to "on which machines".
    return const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_NavActions(), MachineScopeButton()],
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
    final surface = ref.watch(workbenchSurfaceProvider);
    void openScheduler() {
      ref
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.scheduler);
      ref
          .read(navControllerProvider.notifier)
          .commit(const NavLocation(surface: WorkbenchSurface.scheduler));
      closeDrawerIfOverlay(context);
    }

    Widget navigationRow({
      required String label,
      required String icon,
      required bool selected,
      required VoidCallback onTap,
      bool enabled = true,
    }) {
      Widget row = AbListRow(
        title: Text(label, style: AbTokens.sansStyle()),
        leading: AbIcon(
          icon,
          size: AbTokens.iconButtonGlyph,
          color: context.antgrid.textSecondary,
        ),
        density: AbRowDensity.sm,
        horizontalPadding: AbTokens.space8,
        selected: selected,
        selectionStyle: AbRowSelection.surface,
        hoverable: true,
        enabled: enabled,
        onTap: enabled ? onTap : null,
      );
      if (isMobilePlatform) {
        row = ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AbTokens.touchControlMin,
          ),
          child: row,
        );
      }
      return Semantics(selected: selected, enabled: enabled, child: row);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.drawerGutter,
        AbTokens.drawerGutter,
        AbTokens.space4,
      ),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            navigationRow(
              label: 'New Session',
              icon: AbIcons.add,
              // A project panel is the New Session surface too, but the row
              // that is lit then is the project's.
              selected:
                  surface == WorkbenchSurface.newSession &&
                  ref.watch(selectedProjectGroupProvider) == null,
              onTap: () {
                closeProjectPanel(ref.container);
                enterNewSession(ref.container);
              },
            ),
            const SizedBox(height: AbTokens.space4),
            navigationRow(
              label: 'Scheduler',
              icon: AbIcons.calendar,
              selected: surface == WorkbenchSurface.scheduler,
              onTap: openScheduler,
            ),
          ],
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
  /// Owned by [_ProjectsDrawerState] so the PROJECTS refresh button can show
  /// this indicator too.
  final GlobalKey<RefreshIndicatorState> refreshKey;

  /// Null while a refresh the button started is still on screen — see
  /// [_ProjectsDrawerState._refreshBusy].
  final Future<void> Function()? onRefresh;
  const _Body({required this.refreshKey, required this.onRefresh});

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
    // Unfiltered by the session search, by design: that search lives in the
    // title bar and aims at the Recent list. The machine scope is the only
    // filter this list answers to.
    final views = ref.watch(projectViewsProvider);
    if (views.isEmpty) {
      // A scrollable (not a bare Center) so the pull-to-refresh gesture works
      // with zero rows — overscroll needs something scrollable to grab.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          // Kept with nothing under it: its refresh is how a machine whose
          // projects have not loaded yet gets asked again.
          _GroupLabel(label: 'PROJECTS', onRefresh: onRefresh),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AbTokens.space24),
            child:
                // Mobile has no local folders — this drawer fills from machines
                // on the account, so point there.
                isMobilePlatform
                ? const AbEmptyState(
                    title: 'No projects yet',
                    subtitle: 'Connect a machine to see its projects here.',
                  )
                // Desktop's real entry point is a local folder; offer it in
                // place instead of describing where else to find it.
                : const AbEmptyState(
                    title: 'No projects yet',
                    subtitle: 'Open a folder to get started.',
                    action: OpenFolderButton(),
                  ),
          ),
        ],
      );
    }
    final inScope = [
      for (final v in views)
        if (v.inScope) v,
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: AbTokens.space4),
      children: [
        const NeedsYouSection(),
        _GroupLabel(label: 'PROJECTS', onRefresh: onRefresh),
        if (inScope.isEmpty)
          const ScopeHidesEverything()
        else
          for (final v in inScope)
            ProjectGroupRow(key: ValueKey(v.group.key), view: v),
      ],
    );
  }
}

/// Pull-to-refresh / refresh-button handler for the drawer. Re-fetches the
/// machine inventory (HTTPS) and re-pulls the live project advert for every
/// machine in the reaper's alive set. That is not the same as "already open":
/// the set also carries machines a directory read missed, which this app has
/// decided it wants a socket to and is dialling anyway — so the gesture can
/// push one of those dials rather than only refreshing what is up. It still
/// opens nothing for a machine the app has made no such decision about.
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
