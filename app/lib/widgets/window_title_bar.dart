import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_brand_mark.dart';
import '../design/widgets/ab_branch_pill.dart';
import '../design/widgets/ab_breadcrumb.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_window_controls.dart';
import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../utils/platform_utils.dart';
import '../window/window_capabilities.dart';
import '../window/window_chrome.dart';
import 'agent_panel.dart';
import 'session_isolation_badge.dart';
import 'session_mode_control.dart';
import 'session_search_field.dart';

/// The app-drawn window title bar.
///
/// On Linux this renders as an ordinary in-app row beneath the retained OS bar:
/// no drag region, no controls, no inset. It must still render there — the
/// agent-panel header it replaces is deleted on every desktop platform, so
/// skipping it on Linux would lose the breadcrumb, branch pill and chips.
class WindowTitleBar extends ConsumerWidget {
  const WindowTitleBar({super.key, required this.child});

  // A single child, not a children list: wrapping in a Row here would hand the
  // child unbounded width, and the content row's Spacer/Flexible would throw.
  final Widget child;

  @visibleForTesting
  static const dragRegionKey = Key('window-title-bar-drag');

  @visibleForTesting
  static const insetKey = Key('window-title-bar-inset');

  @visibleForTesting
  static const topResizeKey = Key('window-title-bar-top-resize');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = Padding(
      key: insetKey,
      // Static today. In macOS fullscreen the lights auto-hide and this becomes
      // a dead gap — collapsing it is deferred (see the plan's Deferred list).
      padding: EdgeInsets.only(left: titleBarLeftInset),
      // Both wrappers exist because this bar mounts above every route, outside
      // any Material and any Scaffold. Out here the ambient DefaultTextStyle is
      // WidgetsApp's red-on-yellow error style, and `Text.style` merges with
      // it, so its double underline would survive even the fully-specified
      // AbTokens styles. And a TextField — the session search in the middle —
      // asserts outright on a missing Material ancestor. Transparency, so the
      // Material contributes no paint of its own.
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
          child: child,
        ),
      ),
    );

    return Container(
      height: titleBarHeight,
      decoration: BoxDecoration(
        color: context.antgrid.bgDeepest,
        border: Border(bottom: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: appOwnsWindowChrome
          ? Stack(
              children: [
                // Beneath the content so buttons keep their taps; the bar's
                // empty middle is the drag target.
                Positioned.fill(child: _DragRegion()),
                Positioned.fill(child: content),
                if (paintsWindowControls)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    // window_manager's WM_NCCALCSIZE insets the client rect by
                    // 8px on left/right/bottom but leaves the top flush, so the
                    // top edge has no native resize band and would drag instead.
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: _TopResizeStrip(),
                    ),
                  ),
              ],
            )
          : content,
    );
  }
}

class _TopResizeStrip extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chrome = ref.watch(windowChromeProvider);
    return GestureDetector(
      key: WindowTitleBar.topResizeKey,
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => chrome.startResizingTop(),
      child: const SizedBox(height: 4),
    );
  }
}

class _DragRegion extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chrome = ref.watch(windowChromeProvider);
    // No pan-end cleanup: once startDragging() hands the mouse loop to the OS,
    // Flutter never receives the pan-end event, so nothing may depend on it.
    // (The suspected macOS background-drag compounding is handled at init if it
    // reproduces on hardware — see the plan's Deferred list.)
    return GestureDetector(
      key: WindowTitleBar.dragRegionKey,
      behavior: HitTestBehavior.translucent,
      onDoubleTap: chrome.toggleMaximize,
      onPanStart: (_) => chrome.startDragging(),
      onSecondaryTap: paintsWindowControls ? chrome.popUpWindowMenu : null,
      // Touch/stylus only. A mouse long-press must stay a no-op: the arena
      // hands victory to a long press at 500ms, and a pan only claims it once
      // the drag slop is crossed — so press-hold-then-drag, an ordinary way to
      // move a window, would pop the system menu instead of moving anything.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
        },
        onLongPress: paintsWindowControls ? chrome.popUpWindowMenu : null,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Footprint of one icon-button slot in the bar's leading cluster.
///
/// [AbIconButton] scales its box with the ambient text scaler, and on a touch
/// platform [AbTapTarget] floors it at [AbTokens.tapTargetMin] — the bar can
/// still mount on a large tablet in landscape (see `app_shell.dart`). Both the
/// placeholder that holds an unpublished slot open and
/// [WindowTitleBarContents._searchGutter]'s reserve measure it from here, so
/// neither can disagree with what the buttons actually occupy.
@visibleForTesting
double iconSlotExtent(BuildContext context) => math.max(
  MediaQuery.textScalerOf(context).scale(AbTokens.iconButtonBox),
  isMobilePlatform ? AbTokens.tapTargetMin : 0.0,
);

/// Empty stand-in occupying exactly one [iconSlotExtent], for a pane toggle no
/// route has published. A box that doesn't track the button's real footprint
/// lets the row — and the search box centred under it — shift sideways between
/// routes, which is the drift the always-present slot exists to prevent.
class _PaneSlotPlaceholder extends StatelessWidget {
  const _PaneSlotPlaceholder();

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: iconSlotExtent(context));
}

/// Everything the bar carries: the icon row, plus the session search
/// pixel-centred over it in a [Stack] — see [build].
///
/// The row's own middle is deliberately empty — it is the primary drag
/// target, and neither VS Code nor Zed centres a window title there.
class WindowTitleBarContents extends ConsumerWidget {
  const WindowTitleBarContents({super.key});

  @visibleForTesting
  static const modeSlotKey = Key('window-title-bar-mode');

  @visibleForTesting
  static const chipSlotKey = Key('window-title-bar-chip');

  @visibleForTesting
  static const contextPanelSlotKey = Key('window-title-bar-context-panel');

  @visibleForTesting
  static const sidebarSlotKey = Key('window-title-bar-sidebar');

  @visibleForTesting
  static const searchSlotKey = Key('window-title-bar-search');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(contextPanelControlProvider);
    final sidebar = ref.watch(sidebarControlProvider);
    // The agent bar owns the session controls whenever it is up; duplicating
    // them one row higher would say the same thing twice about one session.
    // The New Session/Recent screen (`WorkbenchSurface.newSession`, or no
    // project focused at all) also must not take them back — it has no live
    // session for the controls to describe yet.
    final noProjectFocused = ref.watch(selectedRegistrationIdProvider) == null;
    final onNewSessionScreen =
        noProjectFocused ||
        ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.newSession;
    final showSession =
        !ref.watch(agentBarMountedProvider) && !onNewSessionScreen;

    final nav = ref.watch(navControllerProvider);
    final navNotifier = ref.read(navControllerProvider.notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Pixel-centred on the bar's own width, the way VS Code centres its
        // command/search box — not in the free space left over between the
        // leading and trailing clusters, which drifts off-centre whenever
        // those two clusters aren't the same width. The window-controls
        // strip is carved out on the right first, same as VS Code reserves
        // its caption-button gutter, so the box never sits under
        // minimize/maximize/close, and [_searchGutter] keeps it off the
        // leading cluster and the two pane toggles. The variable trailing
        // chips are NOT reserved for, so on a narrow-enough window the box
        // can still overlap those, same as VS Code's does — hence the paint
        // order below.
        final reservedRight = paintsWindowControls
            ? AbTokens.captionButtonWidth * 3
            : 0.0;
        final centerWidth = (constraints.maxWidth - reservedRight).clamp(
          0.0,
          double.infinity,
        );
        final gutter = _searchGutter(context, centerWidth);
        final region = centerWidth - gutter * 2;
        final button = iconSlotExtent(context);
        // Back/forward travel WITH the search box, not with the leading
        // cluster — VS Code centres its ⟵⟶ immediately beside the command
        // box, so the two must move as one unit for the bar to read the same
        // way. [_searchGutter] reserves this cluster's full width, not just
        // the box's, so it never overlaps the sidebar toggle.
        final searchFloor = math.min(AbTokens.sessionSearchPopupMinWidth, region);
        final searchWidth = math.min(
          math.max(region - button * 2 - AbTokens.space6, searchFloor),
          AbTokens.sessionSearchWidth,
        );
        return Stack(
          children: [
            // Under the row, not over it: an overlap the gutter can't prevent
            // must cost the box its pixels, never the row its taps. A text
            // field spanning the bar swallowed both pane toggles at tablet
            // widths, and those are the only way back to a hidden pane.
            Positioned(
              left: gutter,
              top: 0,
              bottom: 0,
              width: region,
              child: Align(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Enabled by history OR by a handler that has something to
                    // unwind, so the chevron lights up with a file open and no
                    // history yet — and stays dark when the mounted-but-idle
                    // tabs are all a press would find. `revision` is bumped
                    // out of band by the registry (registration happens
                    // mid-build), which is why this listens rather than
                    // watching a provider.
                    ListenableBuilder(
                      listenable: ref
                          .watch(backHandlerRegistryProvider)
                          .revision,
                      builder: (context, _) {
                        final hasActive = ref
                            .read(backHandlerRegistryProvider)
                            .hasActive;
                        return AbIconButton(
                          icon: AbIcons.chevronLeft,
                          tooltip: 'Back',
                          onTap: nav.canBack || hasActive
                              ? () => resolveBackIntent(
                                  ref.container,
                                  allowExit: false,
                                )
                              : null,
                        );
                      },
                    ),
                    AbIconButton(
                      icon: AbIcons.chevronRight,
                      tooltip: 'Forward',
                      onTap: nav.canForward ? navNotifier.forward : null,
                    ),
                    const SizedBox(width: AbTokens.space6),
                    SizedBox(
                      width: searchWidth,
                      child: const KeyedSubtree(
                        key: searchSlotKey,
                        child: SessionSearchField(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _titleBarRow(ref: ref, showSession: showSession, sidebar: sidebar, panel: panel),
          ],
        );
      },
    );
  }

  /// Width held back on EACH side of the centred search cluster (back +
  /// forward + box) so it cannot cover the row's own controls.
  ///
  /// One width for both sides because the cluster is centred: reserving
  /// asymmetrically would shift it off the centre the whole arrangement is
  /// built on. The leading cluster is the wider of the two and its every term
  /// is known without measuring ([iconSlotExtent] covers the text scaler and
  /// the touch floor) — keep in lockstep with [_titleBarRow]'s children up to
  /// its elastic middle; the side of the region facing the trailing row holds
  /// only the context-panel slot.
  ///
  /// Yields to the cluster once the free middle falls below its own floor: at
  /// that window width (or that text scale) no arrangement both clears the
  /// clusters and leaves a legible box, and the row sits above the cluster for
  /// exactly that case.
  static double _searchGutter(BuildContext context, double centerWidth) {
    final button = iconSlotExtent(context);
    final leading =
        AbTokens.space8 +
        AbBrandMark.iconHeight +
        AbTokens.space12 +
        button; // sidebar slot
    final clusterFloor =
        button * 2 + // back + forward
        AbTokens.space6 +
        AbTokens.sessionSearchPopupMinWidth;
    return math.max(
      0.0,
      math.min(leading, (centerWidth - clusterFloor) / 2),
    );
  }

  Widget _titleBarRow({
    required WidgetRef ref,
    required bool showSession,
    required ({bool hidden, VoidCallback toggle})? sidebar,
    required ({bool hidden, VoidCallback toggle})? panel,
  }) {
    return Row(
      children: [
        const SizedBox(width: AbTokens.space8),
        const AbBrandMark.icon(),
        const SizedBox(width: AbTokens.space12),
        // Not beside the panel control at the far right: this governs the
        // leftmost zone on screen, and the two pane toggles sitting at the two
        // edges is what makes each one read as belonging to the pane it opens.
        // Slot always occupies its space even while no control is published
        // yet — both desktop routes (WorkspaceShell and NewSessionScreen)
        // publish one, but only from a post-frame callback, so the very first
        // frame after either mounts is briefly null — a widget that appears
        // and disappears here changes how much room the centred search field
        // below has on the left, and it visibly hops sideways between routes
        // as a result. Unlike [contextPanelSlotKey], `sidebar` is null only in
        // that brief window (every desktop route publishes a real one once
        // mounted), so a same-footprint placeholder is enough here — there's
        // no route where this button should read as permanently disabled.
        KeyedSubtree(
          key: sidebarSlotKey,
          child: sidebar == null
              ? const _PaneSlotPlaceholder()
              : AbIconButton(
                  // Pane-visibility convention, shared with the panel control
                  // below: the glyph depicts the CURRENT state, not the result
                  // of clicking it.
                  icon: sidebar.hidden
                      ? AbIcons.layoutSidebarLeftOff
                      : AbIcons.layoutSidebarLeft,
                  tooltip: sidebar.hidden ? 'Show projects' : 'Hide projects',
                  onTap: sidebar.toggle,
                ),
        ),
        // No breadcrumb here, by design: the session's name belongs above the
        // transcript it names, and the agent bar carries it. Rendering it here
        // too meant a project id appeared in this row on focus and was replaced
        // a frame later by the name one row down, which read as the title
        // sliding out from under the user.
        //
        // The elastic middle carries nothing of its own — the session search
        // is pixel-centred over the whole bar by the Stack in [build], not
        // laid out here, so this is just the gap that keeps the leading and
        // trailing clusters apart and gives the drag region room either side
        // of the search box.
        const Expanded(child: SizedBox.shrink()),
        // The bar only ever mounts at >= kMediumBreakpoint (app_shell.dart),
        // comfortably above the old icon-only tier's floor, so this trailing
        // cluster always fits and no width gate is needed here any more.
        if (showSession) ...[
          const KeyedSubtree(key: modeSlotKey, child: SessionModeControl()),
          const SizedBox(width: AbTokens.space8),
        ],
        KeyedSubtree(
          key: chipSlotKey,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: titleBarProjectActions(ref),
          ),
        ),
        const SizedBox(width: AbTokens.space8),
        // Always shown, unlike the cluster above: hidden is the DEFAULT panel
        // mode on tablets and phone landscape, and dropping this control at
        // narrow widths would strand exactly those users with no way to bring
        // the context panel back.
        //
        // Slot always renders the SAME button, even on routes with no context
        // panel to toggle (New Session/settings) — `onTap: panel?.toggle`
        // falls into AbIconButton's own disabled styling (opacity 0.4, no
        // hover/focus) rather than the button disappearing, which both keeps
        // the bar's right-hand chrome from shifting the centred search field
        // sideways when navigating to and from those routes AND keeps the
        // control visible so it reads as "unavailable here", not missing.
        KeyedSubtree(
          key: contextPanelSlotKey,
          child: AbIconButton(
            icon: (panel?.hidden ?? true)
                ? AbIcons.layoutSidebarRightOff
                : AbIcons.layoutSidebarRight,
            // Same emphasis in both live states: while hidden this button is
            // the ONLY way back (there is no collapsed strip), so dimming it
            // would make the sole recovery affordance the faintest thing in
            // the bar. Omit the tooltip while disabled — there's no action
            // for it to describe.
            tooltip: panel == null
                ? null
                : (panel.hidden ? 'Show context panel' : 'Hide context panel'),
            onTap: panel?.toggle,
          ),
        ),
        const SizedBox(width: AbTokens.space8),
        const AbWindowControls(),
      ],
    );
  }
}

/// The agent name / session breadcrumb, with git branch pill.
///
/// Named for the row it used to live in; both its surfaces are now in
/// `agent_panel.dart` — the mobile header and the desktop `AgentBar` — kept as
/// one widget so the two cannot drift apart.
class TitleBarBreadcrumb extends ConsumerWidget {
  const TitleBarBreadcrumb({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalState = ref.watch(terminalStateProvider).value;
    final activeId = ref.watch(selectedRegistrationIdProvider);
    final agentName =
        terminalState?.agentInfo?.name ??
        (activeId != null ? projectNameFromId(activeId) : 'Antgrid');
    final gitBranch = terminalState?.gitBranch;
    final active = ref.watch(activeSessionProvider);
    // Leaf slot must exist for the '/' separator + leafOverride to render; the
    // string is a fallback only — the editable leaf renders the live name.
    final segments = [agentName, if (active != null) active.name];

    return Row(
      children: [
        Flexible(
          child: AbBreadcrumb(
            segments: segments,
            leafOverride: active == null
                ? null
                : EditableSessionLeaf(session: active),
          ),
        ),
        if (active != null) SessionIsolationBadge(session: active),
        if (gitBranch != null) ...[
          const SizedBox(width: AbTokens.space8),
          // Bounded, not Flexible: the breadcrumb is the only child that should
          // absorb slack, and a second flexible sibling would split it evenly
          // and truncate the name long before the row is actually tight. The
          // cap is what keeps a long branch from making the badge + pill an
          // unshrinkable floor on a narrow window.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: AbBranchPill(
              branch: gitBranch,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: gitBranch));
                if (!context.mounted) return;
                showAbSnackBar(
                  context,
                  'Copied "$gitBranch"',
                  duration: const Duration(seconds: 2),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
