import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preview_models.dart';
import '../navigation/back_intent.dart';
import '../providers/providers.dart';

const double _kPortsMinWidth = 280;
const double _kPortsMaxWidth = 320;

/// Icon button that opens the list of open preview ports, with the open count
/// on a badge. A port list behind one button rather than a docked tab strip
/// leaves the panel's top edge to the address bar.
///
/// Mounts under the Preview screen's Carbon scope. Reads [previewStateProvider]
/// itself so the badge and the open list stay live without the caller
/// threading tab state through; selecting, closing and opening a port stay with
/// the screen because each has side effects (clearing an armed picker, calling
/// the preview service) that belong with it, not this widget.
class PreviewPortsButton extends ConsumerStatefulWidget {
  const PreviewPortsButton({
    super.key,
    required this.onSelected,
    required this.onClosed,
    required this.onOpenPort,
  });

  final ValueChanged<int> onSelected;
  final ValueChanged<int> onClosed;

  /// Runs the open-a-port flow; null disables the list's footer row.
  final VoidCallback? onOpenPort;

  @override
  ConsumerState<PreviewPortsButton> createState() => _PreviewPortsButtonState();
}

class _PreviewPortsButtonState extends ConsumerState<PreviewPortsButton> {
  final _controller = CarbonPopupController();
  final _buttonFocus = FocusNode(debugLabel: 'Open ports');

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onOpenChanged);
  }

  void _onOpenChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onOpenChanged)
      ..dispose();
    _buttonFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(
      previewStateProvider.select((s) => s.value?.tabs.length ?? 0),
    );
    // Above the screen's own back handler: the list is dismissed by this press
    // and nothing beneath it, such as closing the active tab, may also run.
    return BackHandler(
      priority: BackPriority.previewContent + 1,
      active: _controller.isOpen,
      onBack: () {
        _controller.close();
        return true;
      },
      child: CarbonAnchoredPopup(
      controller: _controller,
      restoreFocus: _buttonFocus,
      alignment: CarbonPopupAlignment.end,
      minWidth: _kPortsMinWidth,
      maxWidth: _kPortsMaxWidth,
      popupBuilder: (context, available) => PreviewPortsList(
        maxHeight: available.maxHeight,
        onSelected: (port) {
          _controller.close();
          widget.onSelected(port);
        },
        onClosed: widget.onClosed,
        // Closing first hands focus back to the button, so the address bar
        // the flow focuses next keeps it.
        onOpenPort: widget.onOpenPort == null
            ? null
            : () {
                _controller.close();
                widget.onOpenPort!();
              },
      ),
      child: CarbonButton.iconOnly(
        focusNode: _buttonFocus,
        icon: const CarbonIcon(CarbonIcons.applicationWeb),
        semanticLabel: 'Open ports',
        badgeCount: count == 0 ? null : count,
        badgeTone: CarbonBadgeTone.brand,
        expanded: _controller.isOpen,
        onPressed: _controller.toggle,
      ),
      ),
    );
  }
}

/// The path and query a tab shows, or `/` when it has none.
String _pathOf(PreviewTab tab) {
  final uri = Uri.tryParse(tab.currentUrl ?? '');
  if (uri == null || !uri.hasAuthority) return '/';
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return '${uri.path.isEmpty ? '/' : uri.path}$query';
}

/// Popup content for [PreviewPortsButton]: one row per open port (number and
/// current path), the active port selected, a close button per row, and a
/// footer that opens another port.
///
/// Watches [previewStateProvider] rather than a list passed at open time, so
/// closing a port from here, which keeps the list open, drops its row at once.
/// Up and Down arrows step between the rows and the footer; Tab still reaches
/// each close button.
class PreviewPortsList extends ConsumerStatefulWidget {
  const PreviewPortsList({
    super.key,
    required this.maxHeight,
    required this.onSelected,
    required this.onClosed,
    required this.onOpenPort,
  });

  final double maxHeight;
  final ValueChanged<int> onSelected;
  final ValueChanged<int> onClosed;
  final VoidCallback? onOpenPort;

  @override
  ConsumerState<PreviewPortsList> createState() => _PreviewPortsListState();
}

class _PreviewPortsListState extends ConsumerState<PreviewPortsList> {
  final _root = FocusNode(
    debugLabel: 'Open ports list',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final _footer = FocusNode(debugLabel: 'Open a port');
  final _rows = <int, FocusNode>{};

  FocusNode _rowNode(int port) =>
      _rows.putIfAbsent(port, () => FocusNode(debugLabel: 'Port $port'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(previewStateProvider).value;
      final active = state?.activeTabId;
      final hasActive = state?.tabs.any((t) => t.port == active) ?? false;
      (hasActive ? _rowNode(active!) : _footer).requestFocus();
    });
  }

  @override
  void dispose() {
    _root.dispose();
    _footer.dispose();
    for (final node in _rows.values) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final tabs = ref.read(previewStateProvider).value?.tabs ?? const [];
    final order = [for (final tab in tabs) _rowNode(tab.port), _footer];
    final current = order.indexWhere((n) => n.hasPrimaryFocus);
    // Focus on a close button keeps the default traversal.
    if (current < 0) return KeyEventResult.ignored;
    order[(current + (down ? 1 : -1)).clamp(0, order.length - 1)]
        .requestFocus();
    return KeyEventResult.handled;
  }

  // Focus moves to a neighbour before the row goes, so closing a port does not
  // drop focus out of the open list.
  void _close(List<PreviewTab> tabs, int port) {
    final ports = [for (final tab in tabs) tab.port];
    final i = ports.indexOf(port);
    final neighbour = i + 1 < ports.length
        ? ports[i + 1]
        : (i > 0 ? ports[i - 1] : null);
    (neighbour == null ? _footer : _rowNode(neighbour)).requestFocus();
    widget.onClosed(port);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final state = ref.watch(previewStateProvider).value;
    final tabs = state?.tabs ?? const <PreviewTab>[];
    final activeTabId = state?.activeTabId;
    return Focus(
      focusNode: _root,
      onKeyEvent: _onKey,
      includeSemantics: false,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Open ports',
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.layer(level),
            border: Border.all(color: theme.borderSubtle(level)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: theme.colors.shadow,
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: SingleChildScrollView(
              child: CarbonContainedList(
                label: null,
                variant: CarbonContainedListVariant.disclosed,
                children: [
                  if (tabs.isEmpty)
                    const CarbonContainedListRow(title: 'No ports open'),
                  for (final tab in tabs)
                    _portRow(
                      theme,
                      tab,
                      active: tab.port == activeTabId,
                      tabs: tabs,
                    ),
                  CarbonContainedListRow(
                    title: 'Open a port…',
                    leading: const CarbonIcon(CarbonIcons.add),
                    focusNode: _footer,
                    disabled: widget.onOpenPort == null,
                    onPressed: widget.onOpenPort ?? () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _portRow(
    CarbonThemeData theme,
    PreviewTab tab, {
    required bool active,
    required List<PreviewTab> tabs,
  }) {
    final path = _pathOf(tab);
    return CarbonContainedListRow(
      key: ValueKey(tab.port),
      title: path == '/' ? 'Port ${tab.port}' : 'Port ${tab.port}, $path',
      content: Row(
        spacing: CarbonSpacing.spacing03,
        children: [
          Text(
            '${tab.port}',
            style: theme.typography.code.copyWith(
              color: theme.colors.textPrimary,
            ),
          ),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      selected: active,
      focusNode: _rowNode(tab.port),
      onPressed: () => widget.onSelected(tab.port),
      actions: [
        CarbonButton.iconOnly(
          icon: const CarbonIcon(CarbonIcons.close),
          semanticLabel: 'Close port ${tab.port}',
          size: CarbonButtonSize.small,
          onPressed: () => _close(tabs, tab.port),
        ),
      ],
    );
  }
}
