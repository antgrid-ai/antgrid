import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_menu.dart';
import '../providers/providers.dart';
import 'workspace_tab_bar.dart' show WorkspaceViewBadge;

/// Icon button revealing the list of open preview tabs (open ports) as an
/// anchored popup — a mobile-browser-style tab switcher rather than a
/// permanently docked desktop-IDE tab strip, which left no room at the top
/// of the panel for the address bar. Shows a count badge once more than one
/// tab is open.
///
/// Reads [previewStateProvider] itself (the same pattern [WorkspaceMenuButton]
/// uses for its own control provider) so the badge count and the popup's row
/// list both stay live without the caller threading tab state through.
/// [onSelected]/[onClosed] stay owned by [PreviewScreen] because picking or
/// closing a tab has side effects (clearing an armed element picker, calling
/// the preview service) that belong with the screen, not this widget.
class PreviewTabsButton extends ConsumerStatefulWidget {
  const PreviewTabsButton({
    super.key,
    required this.onSelected,
    required this.onClosed,
  });

  final ValueChanged<int> onSelected;
  final ValueChanged<int> onClosed;

  @override
  ConsumerState<PreviewTabsButton> createState() => _PreviewTabsButtonState();
}

class _PreviewTabsButtonState extends ConsumerState<PreviewTabsButton> {
  final _buttonKey = GlobalKey();

  Future<void> _open() async {
    final anchor = abMenuAnchorRect(_buttonKey.currentContext!);
    if (anchor == null) return;
    final port = await showAbPanel<int>(
      context: _buttonKey.currentContext!,
      anchorRect: anchor,
      width: 280,
      builder: (_) => PreviewTabsPanel(onClosed: widget.onClosed),
    );
    if (port != null) widget.onSelected(port);
  }

  @override
  Widget build(BuildContext context) {
    final tabCount = ref.watch(
      previewStateProvider.select((s) => s.value?.tabs.length ?? 0),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AbIconButton(
          key: _buttonKey,
          icon: AbIcons.previewTabs,
          tooltip: 'Open tabs',
          onTap: tabCount == 0 ? null : _open,
        ),
        if (tabCount > 1)
          Positioned(
            top: -AbTokens.space4,
            right: -AbTokens.space4,
            child: WorkspaceViewBadge(count: tabCount),
          ),
      ],
    );
  }
}

/// Popup content for [PreviewTabsButton]: one row per open tab (port + its
/// current URL), the active tab highlighted, a close action per row.
/// Watches [previewStateProvider] directly rather than a list passed in at
/// open time, so closing a tab from here — which keeps the popup open —
/// updates the row list immediately instead of leaving a stale row behind.
///
/// Public so [PreviewScreen]'s mobile overflow menu can embed the same tab
/// list as one section of its single popup, rather than nesting a second
/// popup inside the first.
class PreviewTabsPanel extends ConsumerWidget {
  const PreviewTabsPanel({super.key, required this.onClosed});

  final ValueChanged<int> onClosed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(previewStateProvider).value;
    final tabs = state?.tabs ?? const [];
    final activeTabId = state?.activeTabId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final tab in tabs)
          AbListRow(
            key: ValueKey(tab.port),
            title: Text(
              'Port ${tab.port}',
              style: AbTokens.monoStyle(
                fontWeight: tab.port == activeTabId
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
            subtitle: tab.currentUrl != null ? Text(tab.currentUrl!) : null,
            selected: tab.port == activeTabId,
            selectionStyle: AbRowSelection.surface,
            hoverable: true,
            actions: [
              AbRowAction(
                icon: AbIcons.close,
                tooltip: 'Close port ${tab.port}',
                tone: AbIconButtonTone.muted,
                onTap: () => onClosed(tab.port),
              ),
            ],
            onTap: () => Navigator.of(context).pop(tab.port),
          ),
      ],
    );
  }
}
