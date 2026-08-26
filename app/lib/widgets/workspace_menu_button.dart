import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_menu.dart';
import '../providers/visible_surface.dart';
import '../utils/platform_utils.dart';
import 'workspace_tab_bar.dart';

/// The agent bar's way into the workspace views: a rail naming all five,
/// anchored under the icon (see the popup doc below) — the SAME rail on a
/// touch tablet as on a mouse desktop, since the touch tablet's context panel
/// is now a docked pane beside the agent (see `WorkspaceShellState._buildTabletTouch`),
/// not an overlay covering it, so the two no longer compete for the same
/// screen space. (Mobile phone width never reaches this widget at all —
/// [workspaceMenuControlProvider] is always null there, since the workspace
/// is a swiped-to page, not a docked panel with a menu into it.)
///
/// A tap ALWAYS just toggles the popup — on every platform, regardless of
/// whether the touch tablet's docked context pane happens to be open or
/// closed. It used to also open the pane directly on a touch tablet when the
/// pane was closed (skipping the popup on the theory that there was nothing
/// to anchor a "pick a view" menu to yet), but that meant a tap could dock
/// the context pane instead of showing the popup the icon is for — the icon
/// must only ever show/hide its own popup, never take a side-effecting
/// shortcut on the pane. Opening the pane is still one tap away: pick any row
/// in the (now visible) popup, which un-hides it — see
/// [WorkspaceMenuPanel]'s doc.
///
/// **The popup is pinned, not modal.** It hangs in the overlay with no
/// barrier, so it survives every click that lands elsewhere — including the
/// ones that drive the agent underneath it — and the icon is the only thing
/// that shuts it BY HAND. That is why it cannot be a [showAbPanel] route: a
/// [PopupRoute] both closes on the first outside click and swallows that click
/// on the way. The trade is that a pinned popup is invisible in the icon's
/// resting look, so the icon latches on ([AbIconButton.selected]) for as long
/// as the rail is up.
///
/// The shell keeps it down for as long as the context pane is on screen, since
/// the pane's own [WorkspaceTabBar] already lists the same five views (see
/// `WorkspaceShellState._syncMenuToContextPane`). What is left for the rail is
/// the one job nothing else can do — the way back to the workspace once the
/// pane is closed.
///
/// Open/closed is [workspaceMenuOpenProvider], not local state — see there for
/// why the button cannot be trusted to remember it.
///
/// Renders nothing when [workspaceMenuControlProvider] is null — the New
/// Session route and the settings overlay have no workspace to reveal, and a
/// menu there would list five views that don't exist yet.
class WorkspaceMenuButton extends ConsumerStatefulWidget {
  const WorkspaceMenuButton({super.key});

  @visibleForTesting
  static const buttonKey = Key('workspace-menu-button');

  @override
  ConsumerState<WorkspaceMenuButton> createState() =>
      _WorkspaceMenuButtonState();
}

class _WorkspaceMenuButtonState extends ConsumerState<WorkspaceMenuButton> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  /// Guarded rather than a bare show/hide: hiding an already-hidden controller
  /// asserts while it is detached, which it is whenever no workspace is
  /// published.
  void _sync(bool open) {
    if (open == _portal.isShowing) return;
    open ? _portal.show() : _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final control = ref.watch(workspaceMenuControlProvider);
    if (control == null) return const SizedBox.shrink();

    final open = ref.watch(workspaceMenuOpenProvider);
    ref.listen(workspaceMenuOpenProvider, (_, next) => _sync(next));
    // Every way the portal can be out of step with the flag, including the
    // first build of all: the flag is app state that outlives this State (see
    // [workspaceMenuOpenProvider]), so a rail that was up when a workbench
    // surface took the agent bar down has to come back up with it, and a
    // session's first rail has to appear with no click at all. Repaired after
    // the frame because show/hide must not run during a build — which also
    // lets the shell's own post-frame pass, registered first from an ancestor
    // build, settle whether the context pane is up before the rail appears
    // over it for a frame.
    if (open != _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(ref.read(workspaceMenuOpenProvider));
      });
    }

    return OverlayPortal(
      controller: _portal,
      // Deliberately no dismiss barrier: a click outside the panel must reach
      // whatever it landed on, unchanged. The Align is what keeps that true —
      // the overlay hands its child the whole screen, and the popup surface's
      // Material paints a shape, whose CustomPaint hit-tests as OPAQUE over
      // every pixel it is given. Screen-sized, it would silently swallow every
      // click in the window while the menu was up. Align loosens the
      // constraints so the surface is only as big as the rail.
      overlayChildBuilder: (_) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          // Right edges flush, hanging under the button. The button lives at
          // the agent bar's trailing edge, so leftward is the only direction
          // the panel can grow and stay inside the window.
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, AbTokens.space4),
          child: const WorkspaceMenuPanel(),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: AbIconButton(
          key: WorkspaceMenuButton.buttonKey,
          icon: AbIcons.workspace,
          selected: open,
          tooltip: 'Workspace',
          onTap: () => ref.read(workspaceMenuOpenProvider.notifier).set(!open),
        ),
      ),
    );
  }
}

/// How far a row's trailing figure is let down while the rail is receded.
/// Still legible, no longer the brightest thing on a surface the reader has
/// not reached for.
const double _restingFigure = 0.6;

/// How long the pointer has to stay before the rail comes forward. A cursor
/// crossing the top-right corner on its way to the agent bar is not a request
/// to read anything, and without this the rail flares at every pass.
const _hoverIntent = Duration(milliseconds: 90);

/// The workspace rail: one row per [WorkspaceView], badged and marked to match
/// the tab strip. Live (a Consumer) so a commit landing or an escalation
/// arriving updates the counts while it is up.
///
/// **It rests receded and comes forward under the pointer.** Pinned over the
/// agent's transcript, a popup at full strength the whole time is a claim on
/// attention it has not earned: at rest it sits translucent over a blur, flat,
/// divided by an ordinary border ([AbPopupSurface.quiet]), with its labels at
/// the muted foreground. Hover or keyboard focus restores the full popup.
///
/// **Only its weight changes, never its size.** A version that furled to an
/// icon column and charged a hover for the labels was built and taken back
/// out: the rail's one job is to say what the workspace holds while the pane
/// is closed, and a rail that has to be reached for before it will answer has
/// stopped doing it.
///
/// Picking a view opens the context pane, which is what takes the rail away —
/// the pane's own tab strip carries on from there (see
/// `WorkspaceShellState._syncMenuToContextPane`).
class WorkspaceMenuPanel extends ConsumerStatefulWidget {
  const WorkspaceMenuPanel({super.key});

  @override
  ConsumerState<WorkspaceMenuPanel> createState() => _WorkspaceMenuPanelState();
}

class _WorkspaceMenuPanelState extends ConsumerState<WorkspaceMenuPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AbTokens.motionDefault,
    // A touch platform has no hover to bring a receded rail back, so it never
    // recedes: the resting state is only earned where the pointer that undoes
    // it exists. Starts forward there and stays that way.
    value: _recedes ? 0 : 1,
  );
  late final CurvedAnimation _lift = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  Timer? _intent;
  bool _hovering = false;
  bool _hasFocus = false;

  bool get _recedes => !isMobilePlatform;

  @override
  void dispose() {
    _intent?.cancel();
    _lift.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setHovering(bool hovering) {
    if (_hovering == hovering) return;
    _hovering = hovering;
    _applyLift(immediate: false);
  }

  void _setFocused(bool hasFocus) {
    if (_hasFocus == hasFocus) return;
    _hasFocus = hasFocus;
    // Keyboard focus skips [_hoverIntent]: Tab landing on a row is already a
    // deliberate arrival, and a row that stayed receded after taking focus is
    // a row the user cannot see they have selected.
    _applyLift(immediate: hasFocus);
  }

  /// The one place hover and keyboard focus meet: the rail stays forward while
  /// EITHER holds and recedes only once neither does. Wired straight to the
  /// controller instead, a pointer leaving dimmed a row that still had the
  /// keyboard, and tabbing out dimmed the rail under a stationary cursor.
  void _applyLift({required bool immediate}) {
    if (!_recedes) return;
    _intent?.cancel();
    if (!_hovering && !_hasFocus) {
      _controller.reverse();
      return;
    }
    // [_hoverIntent] gates the FIRST approach only, so it is armed just from a
    // fully receded rail. Any value above 0 means the rail is already partway
    // forward — approaching, arrived, or withdrawing — and re-arming there
    // would let a pointer that clipped the rail's edge on its way to a row
    // carry on dimming for another 90ms before it turned around, which reads
    // as a dip rather than as hesitation.
    if (immediate || _controller.value > 0) {
      _controller.forward();
    } else {
      _intent = Timer(_hoverIntent, _controller.forward);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Read before the guard below: `_controller` is a `late final`, so a panel
    // that only ever built with a null control would otherwise run the
    // initializer inside `dispose()` — creating a Ticker against a defunct
    // element.
    _controller.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AbTokens.motionDefault;

    final control = ref.watch(workspaceMenuControlProvider);
    final badges = ref.watch(workspaceBadgesProvider);
    final gitStat = ref.watch(gitDiffTotalsProvider);
    if (control == null) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) => _setHovering(true),
      onExit: (_) => _setHovering(false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        // Reports the whole subtree, so this is every row's focus at once.
        onFocusChange: _setFocused,
        child: AnimatedBuilder(
          animation: _lift,
          builder: (context, _) {
            final t = _lift.value;
            return AbPopupSurface(
              quiet: 1 - t,
              // Shrink-wrapped rather than laid out at a fixed width, so the
              // rail ends where its longest label does. A fixed width has to
              // be sized for the widest row the rail can ever hold — the Git
              // row's whole-worktree `+N -M` — which leaves it two thirds
              // empty every other time.
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final view in WorkspaceView.values)
                      _RailRow(
                        view: view,
                        selected: view == control.active,
                        badge: badges[view],
                        gitStat: gitStat,
                        lift: t,
                        onTap: () => control.reveal(view),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One view's row.
class _RailRow extends StatefulWidget {
  const _RailRow({
    required this.view,
    required this.selected,
    required this.badge,
    required this.gitStat,
    required this.lift,
    required this.onTap,
  });

  final WorkspaceView view;

  /// Whether this is the view on screen — not the row under the pointer.
  final bool selected;
  final int? badge;
  final GitDiffTotals gitStat;

  /// 0 while the rail is receded, 1 once it has come forward.
  final double lift;
  final VoidCallback onTap;

  @override
  State<_RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<_RailRow> {
  bool _hover = false;
  bool _focused = false;

  /// The row's trailing figure, and the same fact in words — resolved together
  /// so what a screen reader is told can never drift from what is drawn.
  ///
  /// The Git row trades its file count for the worktree's +/-: how much changed
  /// is what the row is read for, and one trailing figure is all it has room
  /// for. The tab strip deliberately keeps its plain count — five tabs on one
  /// scrolling row have no space for a figure this wide.
  ///
  /// Sized up from [AbDiffStat]'s own default, which is set for the dense
  /// per-file badge in the changed-file tree. Here it shares a column with
  /// [WorkspaceViewBadge] and has to read as the same rank of figure, not as a
  /// footnote wedged in beside the Git label.
  ({Widget figure, String spoken})? _resolveTrailing() {
    final stat = widget.gitStat;
    if (widget.view == WorkspaceView.git &&
        (stat.additions > 0 || stat.deletions > 0)) {
      return (
        figure: AbDiffStat(
          additions: stat.additions,
          deletions: stat.deletions,
          fontSize: AbTokens.fontXs,
        ),
        spoken: AbDiffStat.describe(stat.additions, stat.deletions),
      );
    }
    final badge = widget.badge;
    if (badge == null) return null;
    return (
      figure: WorkspaceViewBadge(count: badge, active: widget.selected),
      spoken: '$badge',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Treat keyboard focus the same as pointer hover for the highlight — one
    // "row under the user" state for either input mode, matching `PanelRow`.
    final under = _hover || _focused;
    final trailing = _resolveTrailing();
    // A receded rail is glanced past, not read: its labels sit at the muted
    // foreground and come up to their own colour along with the surface behind
    // them. The selected row's accent is exempt — which view is on screen is
    // the one thing worth answering without being reached for.
    Color forward(Color arrived) =>
        Color.lerp(p.textMuted, arrived, widget.lift)!;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) {
        if (_hover != v) setState(() => _hover = v);
      },
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Trailing figures draw bare, which announce as a stray digit (or, for
        // the Git row's `+N -M`, as punctuation) after the view's name; folding
        // them into the label is what makes them read as this row's own count —
        // the same treatment, for the same reason, as the tab strip's `_TabItem`.
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: trailing == null
              ? widget.view.label
              : '${widget.view.label}, ${trailing.spoken}',
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space8,
              vertical: AbTokens.space6,
            ),
            decoration: BoxDecoration(
              // The view on screen keeps its own mark under hover: the rail is
              // read for which view is up at least as often as it is clicked.
              color: widget.selected
                  ? p.bgSelected
                  : (under ? p.bgHover : null),
              borderRadius: AbTokens.borderRadius3,
            ),
            child: Row(
              children: [
                AbIcon(
                  widget.view.icon,
                  size: AbTokens.iconButtonGlyph,
                  color: widget.selected
                      ? p.accent
                      : forward(under ? p.textPrimary : p.textSecondary),
                ),
                const SizedBox(width: AbTokens.space8),
                Expanded(
                  child: Text(
                    widget.view.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontSm,
                      color: forward(
                        under || widget.selected
                            ? p.textPrimary
                            : p.textSecondary,
                      ),
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AbTokens.space12),
                  // The figures carry their own colour — the badge's border,
                  // the diffstat's green and red — so they cannot recede by
                  // taking the muted foreground the way the labels do, and a
                  // receded rail would otherwise have its loudest element be
                  // the one thing nobody is looking at. Never to nothing: how
                  // much the worktree has moved is the one fact worth reading
                  // off a rail at rest.
                  Opacity(
                    opacity: lerpDouble(_restingFigure, 1, widget.lift)!,
                    child: trailing.figure,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
