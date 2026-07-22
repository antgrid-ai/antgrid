import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_status_dot.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/terminal_models.dart';
import '../providers/providers.dart';
import '../services/terminal_service.dart';
import 'terminal_detail_view.dart';
import 'terminal_view_wrapper.dart';
import 'ab_status_helpers.dart';

/// List-first terminal view for non-agent terminals with pin support.
///
/// Three view states:
/// 1. **List only** (default) — all non-agent terminals with status/actions.
/// 2. **Pinned** — pinned terminal output on top, remaining list on bottom.
/// 3. **Push navigation** — fullscreen terminal output with back button.
class TerminalListView extends ConsumerStatefulWidget {
  const TerminalListView({super.key});

  @override
  ConsumerState<TerminalListView> createState() => _TerminalListViewState();
}

class _TerminalListViewState extends ConsumerState<TerminalListView> {
  static const int _maxAdHocTerminals = 10;

  String? _pinnedTerminalId;
  String? _pushedTerminalId;

  List<TerminalTab> get _adHocTerminals {
    final terminalState = ref.watch(terminalStateProvider);
    return terminalState.value?.tabs.values
            .where(
              (t) =>
                  t.terminalId != 'agent' &&
                  t.type != 'agent' &&
                  t.type != 'service',
            )
            .toList() ??
        [];
  }

  String _nextAdHocTerminalId(Set<String> existingIds) {
    for (var i = 1; i <= _maxAdHocTerminals; i++) {
      final id = 'terminal-$i';
      if (!existingIds.contains(id)) return id;
    }
    return 'terminal-${DateTime.now().millisecondsSinceEpoch}';
  }

  String _terminalName(String id) => 'Terminal ${id.split('-').last}';

  @override
  Widget build(BuildContext context) {
    final terminalService = serviceWhenReady(ref, terminalServiceProvider);
    if (terminalService == null) {
      return const AbLoading(message: 'loading terminals...');
    }
    final tabs = _adHocTerminals;

    // Push navigation — fullscreen terminal output.
    if (_pushedTerminalId != null) {
      final tab = tabs
          .where((t) => t.terminalId == _pushedTerminalId)
          .firstOrNull;
      if (tab == null) {
        final terminalState = ref.watch(terminalStateProvider);
        final allTabs = terminalState.value?.tabs.values.toList() ?? [];
        final fullTab = allTabs
            .where((t) => t.terminalId == _pushedTerminalId)
            .firstOrNull;
        if (fullTab != null) {
          return _buildPushedView(fullTab, terminalService);
        }
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => setState(() => _pushedTerminalId = null),
        );
        return const SizedBox.shrink();
      }
      return _buildPushedView(tab, terminalService);
    }

    // Pinned — split view.
    if (_pinnedTerminalId != null) {
      final pinnedTab = tabs
          .where((t) => t.terminalId == _pinnedTerminalId)
          .firstOrNull;
      if (pinnedTab == null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => setState(() => _pinnedTerminalId = null),
        );
        return const SizedBox.shrink();
      }
      final remaining = tabs
          .where((t) => t.terminalId != _pinnedTerminalId)
          .toList();
      return _buildPinnedView(pinnedTab, remaining, terminalService);
    }

    // List with header.
    return Column(
      children: [
        _buildHeader(terminalService, tabs),
        Expanded(
          child: tabs.isEmpty
              ? _buildEmptyState(terminalService, tabs)
              : _buildList(tabs, terminalService),
        ),
      ],
    );
  }

  // ── Empty state ──────────────────────────────────────────────────────────

  Widget _buildEmptyState(TerminalService service, List<TerminalTab> tabs) {
    final existingIds = tabs.map((t) => t.terminalId).toSet();
    return AbEmptyState(
      icon: AbIcons.terminal,
      title: 'No terminals',
      subtitle: 'Open a shell to interact with your project',
      action: AbButton(
        label: 'New Terminal',
        leading: AbIcon(AbIcons.add, size: 12, color: context.antgrid.accent),
        onTap: () {
          final id = _nextAdHocTerminalId(existingIds);
          final name = _terminalName(id);
          service.requestStart(id, name: name);
          setState(() => _pushedTerminalId = id);
        },
      ),
    );
  }

  Widget _buildHeader(TerminalService service, List<TerminalTab> tabs) {
    final adHocCount = tabs.length;
    final atLimit = adHocCount >= _maxAdHocTerminals;
    final existingIds = tabs.map((t) => t.terminalId).toSet();
    return AbToolbar.panel(
      title: 'TERMINALS',
      actions: [
        AbIconButton(
          icon: AbIcons.add,
          tooltip: atLimit ? 'Max terminals reached' : 'New terminal',
          onTap: atLimit
              ? null
              : () {
                  final id = _nextAdHocTerminalId(existingIds);
                  final name = _terminalName(id);
                  service.requestStart(id, name: name);
                  setState(() => _pushedTerminalId = id);
                },
        ),
      ],
    );
  }

  // ── List view ────────────────────────────────────────────────────────────

  Widget _buildList(List<TerminalTab> tabs, TerminalService service) {
    return ListView.builder(
      itemCount: tabs.length,
      itemBuilder: (context, index) => _buildTerminalItem(tabs[index], service),
    );
  }

  Widget _buildTerminalItem(TerminalTab tab, TerminalService service) {
    final isRunning = tab.sessionState == TerminalSessionState.running;
    final isExited = tab.sessionState == TerminalSessionState.exited;
    final stateText = isRunning
        ? 'running'
        : isExited
        ? (tab.exitCode != null ? 'exited (${tab.exitCode})' : 'exited')
        : 'starting';
    return AbListRow(
      leading: AbStatusDot(tone: sessionStateTone(tab.sessionState)),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(tab.name, overflow: TextOverflow.ellipsis)),
          if (tab.unread) ...[
            const SizedBox(width: AbTokens.space6),
            Container(
              width: AbTokens.space6,
              height: AbTokens.space6,
              decoration: BoxDecoration(
                color: context.antgrid.accent,
                borderRadius: AbTokens.borderRadiusFull,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(stateText),
      actions: [
        AbRowAction(
          icon: AbIcons.pin,
          tooltip: 'Pin',
          onTap: () => setState(() => _pinnedTerminalId = tab.terminalId),
        ),
        AbRowAction(
          icon: AbIcons.trash,
          tooltip: 'Delete',
          tone: AbIconButtonTone.danger,
          onTap: () {
            setState(() {
              if (_pinnedTerminalId == tab.terminalId) _pinnedTerminalId = null;
              if (_pushedTerminalId == tab.terminalId) _pushedTerminalId = null;
            });
            service.deleteTerminal(tab.terminalId);
          },
        ),
      ],
      divider: true,
      density: AbRowDensity.lg,
      onTap: () {
        // Focusing the terminal clears its unread badge.
        service.setActiveTerminal(tab.terminalId);
        setState(() => _pushedTerminalId = tab.terminalId);
      },
    );
  }

  // ── Push navigation ──────────────────────────────────────────────────────

  Widget _buildPushedView(TerminalTab tab, TerminalService service) {
    return TerminalDetailView(
      tab: tab,
      terminalService: service,
      onBack: () => setState(() => _pushedTerminalId = null),
      onDelete: () {
        final id = tab.terminalId;
        setState(() => _pushedTerminalId = null);
        service.deleteTerminal(id);
      },
    );
  }

  // ── Pinned view ──────────────────────────────────────────────────────────

  Widget _buildPinnedView(
    TerminalTab pinnedTab,
    List<TerminalTab> remaining,
    TerminalService service,
  ) {
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: Column(
        children: [
          // Top: pinned terminal (flex 3).
          Expanded(
            flex: 3,
            child: Column(
              children: [
                // Header.
                SizedBox(
                  height: AbTokens.statusHeaderHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AbTokens.space8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            pinnedTab.name,
                            style: AbTokens.monoStyle(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        AbIconButton(
                          icon: AbIcons.unpin,
                          tooltip: 'Unpin',
                          onTap: () => setState(() => _pinnedTerminalId = null),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: TerminalViewWrapper(
                    tab: pinnedTab,
                    terminalService: service,
                    onDelete: () {
                      final id = pinnedTab.terminalId;
                      setState(() => _pinnedTerminalId = null);
                      service.deleteTerminal(id);
                    },
                  ),
                ),
              ],
            ),
          ),

          // Divider.
          Container(height: 3, color: context.antgrid.borderDefault),

          // Bottom: remaining list (flex 2).
          Expanded(
            flex: 2,
            child: remaining.isEmpty
                ? _buildEmptyState(service, remaining)
                : _buildList(remaining, service),
          ),
        ],
      ),
    );
  }
}
