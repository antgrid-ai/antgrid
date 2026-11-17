import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/ab_colors.dart';
import '../models/agent_work_status.dart';
import '../models/terminal_models.dart';
import '../providers/ad_hoc_terminals.dart';
import '../providers/providers.dart';
import '../providers/session_workspace_state.dart';
import '../services/terminal_service.dart';
import '../util/detached.dart';
import 'carbon_empty_state.dart';
import 'carbon_status_dot.dart';
import 'terminal_view_wrapper.dart';

/// The Terminals tab: the session's own shells, one at a time.
///
/// A tab strip of terminals across the top, and the active one filling the
/// panel below a toolbar naming the folder it runs in.
///
/// The strip, the toolbar and the empty states are Carbon, each in its own
/// scope. The terminal pane is not: [TerminalViewWrapper] is Ab throughout and
/// is shared with the agent panel, so no scope may enclose it.
class TerminalListView extends ConsumerStatefulWidget {
  const TerminalListView({super.key});

  @override
  ConsumerState<TerminalListView> createState() => _TerminalListViewState();
}

class _TerminalListViewState extends ConsumerState<TerminalListView> {
  static const int _maxAdHocTerminals = 10;

  // Not a focus target. It only lets this view find the open terminal's own
  // focus node among its descendants.
  final FocusNode _terminalHost = FocusNode(
    debugLabel: 'TerminalPane',
    canRequestFocus: false,
    skipTraversal: true,
  );

  SessionUiKey? get _uiKey => ref.read(activeSessionUiKeyProvider);

  @override
  void dispose() {
    _terminalHost.dispose();
    super.dispose();
  }

  /// A Carbon tab or button keeps focus once pressed, and the terminal only
  /// autofocuses when nothing holds it, so without this typing after a press
  /// would go to the control. After the frame so a terminal mounted by the same
  /// press already exists.
  void _focusTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final live = _terminalHost.descendants
          .where((n) => n.debugLabel == 'TerminalLiveView')
          .firstOrNull;
      if (live != null && live.canRequestFocus && !live.hasFocus) {
        live.requestFocus();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
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
    _focusTerminal();
  }

  void _select(TerminalService service, String id) {
    // Focusing the terminal clears its unread mark.
    service.setActiveTerminal(id);
    _setSelectedTerminal(id);
  }

  /// Kills [id] and lands on its left neighbour, so closing a tab never leaves
  /// the panel blank while others are still open.
  ///
  /// [shown] is about the tab on screen, which is not always a recorded pick —
  /// after a restart it is the service's focus — and killing it must move on
  /// just the same.
  void _kill(
    TerminalService service,
    List<TerminalTab> tabs,
    String id, {
    required bool shown,
  }) {
    final index = tabs.indexWhere((t) => t.terminalId == id);
    final rest = [
      for (final t in tabs)
        if (t.terminalId != id) t,
    ];
    if (rest.isEmpty) {
      _setSelectedTerminal(null);
    } else if (shown) {
      _select(service, rest[(index - 1).clamp(0, rest.length - 1)].terminalId);
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
      return const AbCarbonScope(
        child: _Surface(
          child: Center(
            child: CarbonInlineLoading(
              status: CarbonInlineLoadingStatus.active,
              description: 'loading terminals...',
            ),
          ),
        ),
      );
    }
    final tabs = ref.watch(adHocTerminalsProvider);
    // Only these fields: TerminalState has no ==, so watching the whole value
    // repainted the pane on every emission.
    final (:attach, :activeTerminalId, :checkoutPath) = ref.watch(
      terminalStateProvider.select((s) {
        final state = s.value;
        return (
          attach: state?.attach ?? CheckoutAttachStatus.unknown,
          activeTerminalId: state?.activeTerminalId,
          checkoutPath: state?.checkoutPath,
        );
      }),
    );

    final picked = tabs.where((t) => t.terminalId == selectedId).firstOrNull;
    // Only once the tab list is the bridge's answer: a reconnect starts a fresh
    // service whose list is empty until agent:status, and forgetting the pick
    // then would land the user on another terminal when the tabs come back.
    if (selectedId != null &&
        picked == null &&
        key != null &&
        attach == CheckoutAttachStatus.ready) {
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
    final active =
        picked ??
        tabs.where((t) => t.terminalId == activeTerminalId).firstOrNull ??
        tabs.firstOrNull;

    final atLimit = tabs.length >= _maxAdHocTerminals;

    // The terminal pane is Ab, so this host paints its backdrop and each
    // Carbon piece paints its own. The slots keep fixed positions so the pane
    // below is never re-parented by the toolbar coming and going.
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AbCarbonScope(
            child: _TabStrip(
              tabs: tabs,
              activeId: active?.terminalId,
              onSelect: (id) {
                _select(service, id);
                _focusTerminal();
              },
              onKill: (id) {
                _kill(service, tabs, id, shown: id == active?.terminalId);
                _focusTerminal();
              },
              onNew: atLimit ? null : () => _createTerminal(service, tabs),
            ),
          ),
          active == null
              ? const SizedBox.shrink()
              : AbCarbonScope(
                  child: _ActiveToolbar(
                    // Empty from an older bridge, which does not report it.
                    path: checkoutPath ?? '',
                    onClear: () {
                      service.clearTerminal(active.terminalId);
                      _focusTerminal();
                    },
                    onRestart: () {
                      service.restartTerminal(active.terminalId);
                      _focusTerminal();
                    },
                    onKill: () {
                      _kill(service, tabs, active.terminalId, shown: true);
                      _focusTerminal();
                    },
                  ),
                ),
          Expanded(
            child: active != null
                ? Focus(
                    focusNode: _terminalHost,
                    child: TerminalViewWrapper(
                      // Switching tabs mounts the next terminal's own view
                      // rather than retargeting this one's state at it.
                      key: ValueKey(active.terminalId),
                      tab: active,
                      terminalService: service,
                    ),
                  )
                : AbCarbonScope(
                    child: _Surface(
                      child: _buildEmptyOrAttaching(service, tabs, attach),
                    ),
                  ),
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
    switch (attach) {
      case CheckoutAttachStatus.attaching:
        return const Center(
          child: CarbonInlineLoading(
            status: CarbonInlineLoadingStatus.active,
            description: 'attaching terminals…',
          ),
        );
      case CheckoutAttachStatus.failed:
        // Retry re-asks for the checkout's status, not one terminal's screen:
        // a checkout-wide failure means no `agent:status` ever arrived.
        return CarbonEmptyState(
          error: true,
          heading: "Couldn't load terminals",
          body: 'the agent has not answered yet',
          // A button set, not a Row: two buttons do not fit a split view at
          // its narrowest, and the set stacks itself.
          action: CarbonButtonSet(
            children: [
              CarbonButton(
                label: 'New Terminal',
                kind: CarbonButtonKind.tertiary,
                icon: const CarbonIcon(CarbonIcons.add),
                onPressed: () => _createTerminal(service, tabs),
              ),
              CarbonButton(
                label: 'Retry',
                onPressed: () => detached(
                  'TerminalListView',
                  'retry checkout attach failed',
                  service.retryCheckoutAttach,
                ),
              ),
            ],
          ),
        );
      case CheckoutAttachStatus.unknown:
      case CheckoutAttachStatus.ready:
        return CarbonEmptyState(
          icon: CarbonIcons.terminal,
          heading: 'No terminals running',
          action: CarbonButton(
            label: 'New Terminal',
            icon: const CarbonIcon(CarbonIcons.add),
            onPressed: () => _createTerminal(service, tabs),
          ),
        );
    }
  }
}

/// A Carbon piece's own backdrop, with an optional rule under it.
class _Surface extends StatelessWidget {
  const _Surface({this.rule = false, required this.child});

  final bool rule;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colors.background,
        border: rule
            ? Border(
                bottom: BorderSide(
                  color: t.borderSubtle(CarbonLayer.of(context)),
                  width: CarbonBorders.hairline,
                ),
              )
            : null,
      ),
      child: child,
    );
  }
}

/// The terminals as contained, dismissible tabs. New stays pinned outside the
/// tabs' own scrolling, so opening a terminal never means scrolling to find
/// the button.
///
/// Activation is manual: every terminal a tab selects mounts its own keyed
/// view, so arrowing across the strip must not mount each one on the way.
class _TabStrip extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    // The tabs' own height, held while there are none so the strip does not
    // jump when the first terminal opens.
    final minHeight = math.max(
      t.isTouch ? t.touchTarget : CarbonSizes.md,
      t.minTarget,
    );
    return _Surface(
      rule: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Row(
          children: [
            Expanded(
              child: tabs.isEmpty
                  ? const SizedBox.shrink()
                  : CarbonTabs<String>(
                      variant: CarbonTabsVariant.contained,
                      activation: CarbonActivationMode.manual,
                      semanticLabel: 'Terminals',
                      value: activeId,
                      onChanged: onSelect,
                      // Re-pressing the open tab hands typing back to it.
                      onReselect: onSelect,
                      // Mice with no horizontal wheel can still reach every tab.
                      wheelScrollsSideways: true,
                      onClose: onKill,
                      closeLabelBuilder: (name) => 'Kill $name',
                      tabs: [
                        for (final tab in tabs)
                          CarbonOption<String>(
                            value: tab.terminalId,
                            label: tab.name,
                            semanticLabel: '${tab.name}, ${_stateLabel(tab)}',
                            leading: _TabDots(
                              tab: tab,
                              active: tab.terminalId == activeId,
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CarbonSpacing.spacing03,
              ),
              child: _NewButton(onTap: onNew),
            ),
          ],
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

/// The run state as a dot, and a second one while the terminal has output
/// nobody has seen. The tab's spoken name carries the state, so the dots are
/// decoration.
class _TabDots extends StatelessWidget {
  const _TabDots({required this.tab, required this.active});

  final TerminalTab tab;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = CarbonTheme.of(context).colors;
    final color = switch (tab.sessionState) {
      TerminalSessionState.running => c.supportSuccess,
      TerminalSessionState.exited => c.supportError,
      TerminalSessionState.starting => c.iconSecondary,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: CarbonSpacing.spacing02,
      children: [
        CarbonStatusDot(color: color),
        if (tab.unread && !active)
          const CarbonWorkStatusDot(status: AgentWorkStatus.unread),
      ],
    );
  }
}

class _NewButton extends StatelessWidget {
  const _NewButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    // Focusable while disabled so the reason is reachable from the keyboard.
    return CarbonTooltip(
      message: enabled ? 'New terminal' : 'Max terminals reached',
      child: CarbonButton(
        label: 'New',
        semanticLabel: 'New terminal',
        kind: CarbonButtonKind.ghost,
        size: CarbonButtonSize.small,
        icon: const CarbonIcon(CarbonIcons.add),
        onPressed: onTap,
        focusableWhenDisabled: true,
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
    final t = CarbonTheme.of(context);
    return _Surface(
      rule: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Three labelled buttons beside a path stop fitting in a narrow pane.
          final folded = constraints.maxWidth < CarbonSpacing.spacing09 * 8;
          return Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: CarbonSpacing.spacing05,
                    end: CarbonSpacing.spacing03,
                  ),
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.code.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                ),
              ),
              if (folded)
                CarbonOverflowMenu(
                  horizontal: true,
                  semanticLabel: 'Terminal actions',
                  entries: [
                    CarbonMenuItem(label: 'Clear', onPressed: onClear),
                    CarbonMenuItem(label: 'Restart', onPressed: onRestart),
                    CarbonMenuItem(
                      label: 'Kill',
                      kind: CarbonMenuItemKind.danger,
                      onPressed: onKill,
                    ),
                  ],
                )
              else ...[
                CarbonButton(
                  label: 'Clear',
                  kind: CarbonButtonKind.ghost,
                  size: CarbonButtonSize.small,
                  onPressed: onClear,
                ),
                CarbonButton(
                  label: 'Restart',
                  kind: CarbonButtonKind.ghost,
                  size: CarbonButtonSize.small,
                  onPressed: onRestart,
                ),
                CarbonButton(
                  label: 'Kill',
                  kind: CarbonButtonKind.dangerGhost,
                  size: CarbonButtonSize.small,
                  onPressed: onKill,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
