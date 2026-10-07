import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/ab_status_tone.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/terminal_models.dart';
import '../providers/ad_hoc_terminals.dart';
import '../providers/providers.dart';
import '../providers/session_workspace_state.dart';
import '../services/terminal_service.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'ab_status_helpers.dart';
import 'terminal_view_wrapper.dart';

/// The Terminals tab: the session's own shells, one at a time.
///
/// A tab strip of terminals across the top, the active one filling the panel
/// below a toolbar naming the folder it runs in, and — on desktop — a footer
/// with the running count.
class TerminalListView extends ConsumerStatefulWidget {
  const TerminalListView({super.key});

  @override
  ConsumerState<TerminalListView> createState() => _TerminalListViewState();
}

class _TerminalListViewState extends ConsumerState<TerminalListView> {
  static const int _maxAdHocTerminals = 10;

  SessionUiKey? get _uiKey => ref.read(activeSessionUiKeyProvider);

  String? get _selectedTerminalId {
    final key = _uiKey;
    return key == null
        ? null
        : ref.read(sessionWorkspaceStateProvider(key)).selectedTerminalId;
  }

  void _setSelectedTerminal(String? id) {
    final key = _uiKey;
    if (key == null) return;
    ref
        .read(sessionWorkspaceStateProvider(key).notifier)
        .update(
          (s) => s.copyWith(
            selectedTerminalId: id,
            clearSelectedTerminalId: id == null,
          ),
        );
  }

  String _nextAdHocTerminalId(Set<String> existingIds) {
    for (var i = 1; i <= _maxAdHocTerminals; i++) {
      final id = 'terminal-$i';
      if (!existingIds.contains(id)) return id;
    }
    return 'terminal-${DateTime.now().millisecondsSinceEpoch}';
  }

  void _createTerminal(TerminalService service, List<TerminalTab> tabs) {
    if (tabs.length >= _maxAdHocTerminals) return;
    final id = _nextAdHocTerminalId(tabs.map((t) => t.terminalId).toSet());
    service.createAdHocTerminal(id, name: 'Terminal ${id.split('-').last}');
    _setSelectedTerminal(id);
  }

  void _select(TerminalService service, String id) {
    // Focusing the terminal clears its unread mark.
    service.setActiveTerminal(id);
    _setSelectedTerminal(id);
  }

  /// Kills [id] and lands on its left neighbour, so closing a tab never leaves
  /// the panel blank while others are still open.
  void _kill(TerminalService service, List<TerminalTab> tabs, String id) {
    final index = tabs.indexWhere((t) => t.terminalId == id);
    final rest = [
      for (final t in tabs)
        if (t.terminalId != id) t,
    ];
    if (_selectedTerminalId == id || rest.isEmpty) {
      final next = rest.isEmpty
          ? null
          : rest[(index - 1).clamp(0, rest.length - 1)].terminalId;
      _setSelectedTerminal(next);
    }
    service.deleteTerminal(id);
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(activeSessionUiKeyProvider);
    final selectedId = key == null
        ? null
        : ref.watch(sessionWorkspaceStateProvider(key)).selectedTerminalId;
    final service = serviceWhenReady(ref, terminalServiceProvider);
    if (service == null) {
      return const AbLoading(message: 'loading terminals...');
    }
    final tabs = ref.watch(adHocTerminalsProvider);
    final state = ref.watch(terminalStateProvider).value;
    final attach = state?.attach ?? CheckoutAttachStatus.unknown;

    var active = tabs.where((t) => t.terminalId == selectedId).firstOrNull;
    if (selectedId != null && active == null && key != null) {
      // Deleted or gone from the bridge: forget it after this frame.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref
            .read(sessionWorkspaceStateProvider(key).notifier)
            .update((s) => s.copyWith(clearSelectedTerminalId: true)),
      );
    }
    // No pick recorded for this session (none made yet, or no session key to
    // file one under): the service's own focus, which New and a tab tap both
    // move, then the first tab.
    active ??=
        tabs.where((t) => t.terminalId == state?.activeTerminalId).firstOrNull ??
        tabs.firstOrNull;

    final atLimit = tabs.length >= _maxAdHocTerminals;

    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabStrip(
            tabs: tabs,
            activeId: active?.terminalId,
            onSelect: (id) => _select(service, id),
            onKill: (id) => _kill(service, tabs, id),
            onNew: atLimit ? null : () => _createTerminal(service, tabs),
          ),
          if (active != null)
            _ActiveToolbar(
              // Empty from an older bridge, which does not report it.
              path: state?.checkoutPath ?? '',
              onClear: () => service.clearTerminal(active!.terminalId),
              onRestart: () => service.restartTerminal(active!.terminalId),
              onKill: () => _kill(service, tabs, active!.terminalId),
            ),
          Expanded(
            child: active != null
                ? TerminalViewWrapper(
                    // Switching tabs mounts the next terminal's own view
                    // rather than retargeting this one's state at it.
                    key: ValueKey(active.terminalId),
                    tab: active,
                    terminalService: service,
                  )
                : _buildEmptyOrAttaching(service, tabs, attach),
          ),
        ],
      ),
    );
  }

  /// The nothing-to-show surface, forked on whether the checkout has actually
  /// finished attaching: "No terminals" is a claim about the project, so it
  /// may only be made once the app knows there are none.
  Widget _buildEmptyOrAttaching(
    TerminalService service,
    List<TerminalTab> tabs,
    CheckoutAttachStatus attach,
  ) {
    final newButton = AbButton(
      label: 'New Terminal',
      leading: AbIcon(AbIcons.add, size: 12, color: context.antgrid.accent),
      onTap: () => _createTerminal(service, tabs),
    );
    switch (attach) {
      case CheckoutAttachStatus.attaching:
        return const AbEmptyState.compact(title: 'attaching terminals…');
      case CheckoutAttachStatus.failed:
        // Retry re-asks for the checkout's status, not one terminal's screen:
        // a checkout-wide failure means no `agent:status` ever arrived.
        return AbEmptyState.error(
          title: "Couldn't load terminals",
          subtitle: 'the agent has not answered yet',
          // Wrapped, not a Row: two buttons do not fit a split view at its
          // narrowest.
          action: Wrap(
            spacing: AbTokens.space8,
            alignment: WrapAlignment.center,
            children: [
              AbButton(
                label: 'Retry',
                color: context.antgrid.accent,
                onTap: () => detached(
                  'TerminalListView',
                  'retry checkout attach failed',
                  service.retryCheckoutAttach,
                ),
                compact: true,
              ),
              newButton,
            ],
          ),
        );
      case CheckoutAttachStatus.unknown:
      case CheckoutAttachStatus.ready:
        return AbEmptyState(
          icon: AbIcons.terminal,
          title: 'No terminals running',
          action: newButton,
        );
    }
  }
}

/// The pills scroll sideways once they outgrow the pane: by swipe on touch,
/// and on desktop by the wheel or the chevrons that appear at an edge with
/// more pills past it. New stays pinned outside the scroll, so opening a
/// terminal never means scrolling to find the button.
class _TabStrip extends StatefulWidget {
  const _TabStrip({
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onKill,
    required this.onNew,
  });

  final List<TerminalTab> tabs;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onKill;

  /// Null at the terminal cap.
  final VoidCallback? onNew;

  @override
  State<_TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<_TabStrip> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _pillKeys = {};
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealActive());
  }

  @override
  void didUpdateWidget(_TabStrip old) {
    super.didUpdateWidget(old);
    // A new tab lands at the end, past the edge on a crowded strip; a tab
    // picked another way (a notification, a restored session) can be off it
    // too. Either way the open terminal's pill should be the one on screen.
    if (old.activeId != widget.activeId ||
        old.tabs.length != widget.tabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealActive());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncEdges() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final back = pos.pixels > pos.minScrollExtent + 0.5;
    final forward = pos.pixels < pos.maxScrollExtent - 0.5;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  /// Scrolls the least distance that puts the active pill fully on screen,
  /// and not at all when it already is.
  void _revealActive() {
    if (!mounted || !_scroll.hasClients) return;
    final box = _pillKeys[widget.activeId]?.currentContext?.findRenderObject();
    final viewport = box == null ? null : RenderAbstractViewport.maybeOf(box);
    if (box != null && viewport != null) {
      final pos = _scroll.position;
      final atStart = viewport.getOffsetToReveal(box, 0).offset;
      final atEnd = viewport.getOffsetToReveal(box, 1).offset;
      final target = pos.pixels > atStart
          ? atStart
          : pos.pixels < atEnd
          ? atEnd
          : null;
      if (target != null) {
        detached(
          'TerminalTabStrip',
          'reveal active tab failed',
          () => _scroll.animateTo(
            target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
            duration: AbTokens.motionSnap,
            curve: Curves.easeOut,
          ),
        );
      }
    }
    _syncEdges();
  }

  /// Moves most of a pane-width, keeping a sliver of the last view so the
  /// eye has something to anchor on.
  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (pos.pixels + direction * pos.viewportDimension * 0.7)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    detached(
      'TerminalTabStrip',
      'page tabs failed',
      () => _scroll.animateTo(
        target,
        duration: AbTokens.motionSnap,
        curve: Curves.easeOut,
      ),
    );
  }

  /// A mouse wheel only scrolls vertically; on a sideways strip that is the
  /// gesture a desktop user reaches for first.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final pos = _scroll.position;
    _scroll.jumpTo(
      (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final ids = {for (final t in widget.tabs) t.terminalId};
    _pillKeys.removeWhere((id, _) => !ids.contains(id));
    final desktop = !isMobilePlatform;

    final pills = NotificationListener<ScrollMetricsNotification>(
      // Fires when the content or viewport changes size (a tab added or
      // killed, the pane resized), which the scroll listener alone misses.
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncEdges());
        return false;
      },
      child: Listener(
        onPointerSignal: desktop ? _onPointerSignal : null,
        // Not a lazy ListView: the active pill is scrolled TO, so it has to
        // exist while off screen, and the strip holds at most a handful.
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
          child: Row(
            children: [
              for (final t in widget.tabs) ...[
                _TerminalPill(
                  key: _pillKeys.putIfAbsent(t.terminalId, GlobalKey.new),
                  tab: t,
                  active: t.terminalId == widget.activeId,
                  onTap: () => widget.onSelect(t.terminalId),
                  onKill: () => widget.onKill(t.terminalId),
                ),
                const SizedBox(width: AbTokens.space4),
              ],
            ],
          ),
        ),
      ),
    );

    return Container(
      height: AbTokens.rowHeightMd,
      decoration: BoxDecoration(
        color: p.bgDeep,
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Row(
        children: [
          if (desktop && _canBack)
            AbIconButton(
              icon: AbIcons.chevronLeft,
              tooltip: 'Scroll terminals left',
              onTap: () => _page(-1),
            ),
          Expanded(child: pills),
          if (desktop && _canForward)
            AbIconButton(
              icon: AbIcons.chevronRight,
              tooltip: 'Scroll terminals right',
              onTap: () => _page(1),
            ),
          Padding(
            padding: const EdgeInsets.only(
              left: AbTokens.space4,
              right: AbTokens.space8,
            ),
            child: _NewButton(onTap: widget.onNew),
          ),
        ],
      ),
    );
  }
}

class _TerminalPill extends StatefulWidget {
  const _TerminalPill({
    super.key,
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onKill,
  });

  final TerminalTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onKill;

  @override
  State<_TerminalPill> createState() => _TerminalPillState();
}

class _TerminalPillState extends State<_TerminalPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final tab = widget.tab;
    return Semantics(
      button: true,
      selected: widget.active,
      label: '${tab.name}, ${_stateLabel(tab)}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: AbTokens.rowHeightXs,
            padding: const EdgeInsets.only(
              left: AbTokens.space10,
              right: AbTokens.space4,
            ),
            decoration: BoxDecoration(
              color: widget.active
                  ? p.bgRaised
                  : _hovered
                  ? p.bgHover
                  : null,
              border: Border.all(
                color: widget.active ? p.borderDefault : Colors.transparent,
              ),
              borderRadius: AbTokens.borderRadius5,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RunDot(state: tab.sessionState),
                const SizedBox(width: AbTokens.space8),
                Text(
                  tab.name,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w500,
                    color: widget.active || tab.unread
                        ? p.textPrimary
                        : p.textSecondary,
                  ),
                ),
                if (tab.unread && !widget.active) ...[
                  const SizedBox(width: AbTokens.space6),
                  Container(
                    width: AbTokens.dotSizeSm,
                    height: AbTokens.dotSizeSm,
                    decoration: BoxDecoration(
                      color: p.unread,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
                const SizedBox(width: AbTokens.space4),
                AbIconButton(
                  icon: AbIcons.close,
                  tone: AbIconButtonTone.muted,
                  tooltip: 'Kill terminal',
                  boxSize: 20,
                  glyphSize: 12,
                  onTap: widget.onKill,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _stateLabel(TerminalTab tab) => switch (tab.sessionState) {
  TerminalSessionState.running => 'running',
  TerminalSessionState.starting => 'starting',
  TerminalSessionState.exited =>
    tab.exitCode == null ? 'exited' : 'exited (${tab.exitCode})',
};

/// Running reads as a lit dot with a halo; anything else is a plain dot in
/// the state's own tone.
class _RunDot extends StatelessWidget {
  const _RunDot({required this.state});

  final TerminalSessionState state;

  @override
  Widget build(BuildContext context) {
    final color = sessionStateTone(state).color(context);
    final running = state == TerminalSessionState.running;
    return Container(
      width: AbTokens.dotSizeSm + 1,
      height: AbTokens.dotSizeSm + 1,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: running
            ? Border.all(
                color: color.withValues(alpha: 0.15),
                width: 3,
                strokeAlign: BorderSide.strokeAlignOutside,
              )
            : null,
      ),
    );
  }
}

class _NewButton extends StatefulWidget {
  const _NewButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  State<_NewButton> createState() => _NewButtonState();
}

class _NewButtonState extends State<_NewButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final enabled = widget.onTap != null;
    final lit = enabled && _hovered;
    final color = lit ? p.accent : p.textSecondary;
    return AbTooltip(
      message: enabled ? 'New terminal' : 'Max terminals reached',
      child: Semantics(
        button: true,
        enabled: enabled,
        label: 'New terminal',
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Opacity(
              opacity: enabled ? 1 : AbTokens.opacityDisabled,
              child: Container(
                height: AbTokens.rowHeightXs,
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space10,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: lit ? p.accent : p.borderDefault),
                  borderRadius: AbTokens.borderRadius5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AbIcon(AbIcons.add, size: 12, color: color),
                    const SizedBox(width: AbTokens.space6),
                    Text(
                      'New',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontSm,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveToolbar extends StatelessWidget {
  const _ActiveToolbar({
    required this.path,
    required this.onClear,
    required this.onRestart,
    required this.onKill,
  });

  final String path;
  final VoidCallback onClear;
  final VoidCallback onRestart;
  final VoidCallback onKill;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      height: AbTokens.rowHeightMd,
      padding: const EdgeInsets.only(
        left: AbTokens.space12,
        right: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontSm,
                color: p.textMuted,
              ),
            ),
          ),
          _ToolbarAction(label: 'Clear', onTap: onClear),
          _ToolbarAction(label: 'Restart', onTap: onRestart),
          _ToolbarAction(label: 'Kill', onTap: onKill, danger: true),
        ],
      ),
    );
  }
}

/// A borderless text action: three bordered buttons in a row would outweigh
/// the path they sit beside.
class _ToolbarAction extends StatefulWidget {
  const _ToolbarAction({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_ToolbarAction> createState() => _ToolbarActionState();
}

class _ToolbarActionState extends State<_ToolbarAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final rest = widget.danger ? p.error : p.textSecondary;
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: AbTokens.rowHeightXs,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space10),
            decoration: BoxDecoration(
              color: _hovered
                  ? (widget.danger
                        ? p.error.withValues(alpha: 0.12)
                        : p.bgHover)
                  : null,
              borderRadius: AbTokens.borderRadius5,
            ),
            child: Text(
              widget.label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: _hovered && !widget.danger ? p.textPrimary : rest,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
