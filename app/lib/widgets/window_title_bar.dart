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
import '../navigation/nav_controller.dart';
import '../providers/agent_transport.dart';
import '../providers/project_work_status.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../services/control_plane_client.dart' show AgentWorkStatus;
import '../window/window_capabilities.dart';
import '../window/window_chrome.dart';
import 'agent_panel.dart';
import 'agent_work_status_dot.dart';
import 'session_mode_control.dart';

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
      // The bar mounts above every route, outside any Material, where the
      // ambient DefaultTextStyle is WidgetsApp's red-on-yellow error style —
      // and `Text.style` merges with it, so its double underline would survive
      // even the fully-specified AbTokens styles.
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
        child: child,
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

/// Everything the bar carries, in one row.
///
/// The middle is deliberately empty — it is the primary drag target, and
/// neither VS Code nor Zed centres a window title there.
class WindowTitleBarContents extends ConsumerWidget {
  const WindowTitleBarContents({super.key});

  @visibleForTesting
  static const modeSlotKey = Key('window-title-bar-mode');

  @visibleForTesting
  static const handlerSlotKey = Key('window-title-bar-handler');

  @visibleForTesting
  static const chipSlotKey = Key('window-title-bar-chip');

  @visibleForTesting
  static const contextPanelSlotKey = Key('window-title-bar-context-panel');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final showTrailing = width >= kTitleBarTierIconOnly;
    final panel = ref.watch(contextPanelControlProvider);

    final nav = ref.watch(navControllerProvider);
    final navNotifier = ref.read(navControllerProvider.notifier);

    return Row(
      children: [
        const SizedBox(width: AbTokens.space8),
        const AbBrandMark.icon(),
        const SizedBox(width: AbTokens.space12),
        AbIconButton(
          icon: AbIcons.chevronLeft,
          tooltip: 'Back',
          onTap: nav.canBack ? navNotifier.back : null,
        ),
        AbIconButton(
          icon: AbIcons.chevronRight,
          tooltip: 'Forward',
          onTap: nav.canForward ? navNotifier.forward : null,
        ),
        const SizedBox(width: AbTokens.space8),
        const Flexible(child: TitleBarBreadcrumb()),
        // Elastic gap: keeps the centre free for dragging and pushes trailing
        // items to the right edge.
        const Spacer(),
        if (showTrailing) ...[
          const KeyedSubtree(
            key: modeSlotKey,
            child: SessionModeControl(),
          ),
          const SizedBox(width: AbTokens.space8),
          const KeyedSubtree(
            key: handlerSlotKey,
            child: HandlerHeaderControl(),
          ),
          const SizedBox(width: AbTokens.space8),
          KeyedSubtree(
            key: chipSlotKey,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: titleBarProjectActions(ref),
            ),
          ),
          const SizedBox(width: AbTokens.space8),
        ],
        // Outside the trailing tier deliberately: hidden is the DEFAULT panel
        // mode on tablets and phone landscape, and dropping this control at
        // narrow widths would strand exactly those users with no way to bring
        // the context panel back.
        if (panel != null) ...[
          KeyedSubtree(
            key: contextPanelSlotKey,
            child: AbIconButton(
              icon: panel.hidden
                  ? AbIcons.layoutSidebarRightOff
                  : AbIcons.layoutSidebarRight,
              // Same emphasis in both states: while hidden this button is the
              // ONLY way back (there is no collapsed strip), so dimming it
              // would make the sole recovery affordance the faintest thing in
              // the bar.
              tooltip: panel.hidden
                  ? 'Show context panel'
                  : 'Hide context panel',
              onTap: panel.toggle,
            ),
          ),
          const SizedBox(width: AbTokens.space8),
        ],
        const AbWindowControls(),
      ],
    );
  }
}

/// The agent name / session breadcrumb, with git branch pill.
///
/// Shared by the desktop [WindowTitleBarContents] and the mobile-only header
/// in `agent_panel.dart` — kept as one widget so the two surfaces cannot
/// drift apart.
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
    // Live work status for the focused project — working/attention/error next
    // to the breadcrumb. Omitted when done to keep an idle bar clean.
    final workStatus = activeId != null
        ? ref.watch(projectWorkStatusProvider(activeId))
        : null;

    return Row(
      children: [
        if (workStatus != null && workStatus != AgentWorkStatus.done) ...[
          AgentWorkStatusDot(status: workStatus),
          const SizedBox(width: AbTokens.space8),
        ],
        Flexible(
          child: AbBreadcrumb(
            segments: segments,
            leafOverride: active == null
                ? null
                : EditableSessionLeaf(session: active),
          ),
        ),
        if (gitBranch != null) ...[
          const SizedBox(width: AbTokens.space8),
          AbBranchPill(
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
        ],
      ],
    );
  }
}
