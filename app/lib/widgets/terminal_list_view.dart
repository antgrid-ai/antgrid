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
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_status_dot.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/session_entry.dart';
import '../models/terminal_models.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/session_workspace_state.dart';
import '../services/terminal_service.dart';
import '../util/detached.dart';
import 'terminal_view_wrapper.dart';
import 'ab_status_helpers.dart';

/// List-first terminal view for non-agent terminals.
///
/// Two view states:
/// 1. **List only** (default) — all non-agent terminals with status/actions.
/// 2. **Selected** — the selected terminal's output on top and the rest of
///    the list below, so switching terminals is one tap on a row rather than a
///    trip back out through a separate screen.
class TerminalListView extends ConsumerStatefulWidget {
  const TerminalListView({super.key});

  @override
  ConsumerState<TerminalListView> createState() => _TerminalListViewState();
}

class _TerminalListViewState extends ConsumerState<TerminalListView> {
  static const int _maxAdHocTerminals = 10;

  SessionUiKey? get _uiKey => ref.read(activeSessionUiKeyProvider);

  SessionWorkspaceState get _uiState {
    final key = _uiKey;
    return key == null
        ? const SessionWorkspaceState()
        : ref.read(sessionWorkspaceStateProvider(key));
  }

  String? get _selectedTerminalId => _uiState.selectedTerminalId;

  void _updateTerminalUiFor(
    SessionUiKey key,
    SessionWorkspaceState Function(SessionWorkspaceState) change,
  ) {
    ref.read(sessionWorkspaceStateProvider(key).notifier).update(change);
  }

  void _setSelectedTerminal(String? id) {
    final key = _uiKey;
    if (key == null) return;
    _updateTerminalUiFor(
      key,
      (s) => s.copyWith(
        selectedTerminalId: id,
        clearSelectedTerminalId: id == null,
      ),
    );
  }

  /// The PTYs carrying a checkout's `worktree.setup` transcript.
  ///
  /// Excluded from the list below because the ad-hoc filter selects by
  /// EXCLUSION — a terminal typed neither `agent` nor `service` is "a user
  /// terminal", and a setup transcript carries no type at all. Left in, a
  /// provisioning log would list as an interactive tab the user can type into
  /// and close, killing a live `bun install` mid-install. Named off
  /// `SessionSetup.terminalId`, the bridge's own answer for which PTY carries
  /// the transcript, rather than pattern-matched off the id.
  Set<String> get _setupTerminalIds {
    final sessions =
        ref.watch(freshSessionsStateProvider)?.sessions ??
        const <SessionEntry>[];
    return {for (final s in sessions) ?s.setup?.terminalId};
  }

  List<TerminalTab> get _adHocTerminals {
    final terminalState = ref.watch(terminalStateProvider);
    final setupIds = _setupTerminalIds;
    return terminalState.value?.tabs.values
            .where(
              (t) =>
                  t.terminalId != 'agent' &&
                  t.type != 'agent' &&
                  t.type != 'service' &&
                  !setupIds.contains(t.terminalId),
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

  void _createTerminal(TerminalService service, List<TerminalTab> tabs) {
    final id = _nextAdHocTerminalId(tabs.map((t) => t.terminalId).toSet());
    service.createAdHocTerminal(id, name: _terminalName(id));
    _setSelectedTerminal(id);
  }

  void _deleteTerminal(TerminalService service, String id) {
    if (_selectedTerminalId == id) _setSelectedTerminal(null);
    service.deleteTerminal(id);
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(activeSessionUiKeyProvider);
    if (key != null) ref.watch(sessionWorkspaceStateProvider(key));
    final terminalService = serviceWhenReady(ref, terminalServiceProvider);
    if (terminalService == null) {
      return const AbLoading(message: 'loading terminals...');
    }
    final tabs = _adHocTerminals;
    // `select` so the list is not rebuilt by per-terminal hydration churn on
    // the same state object.
    final attach = ref.watch(
      terminalStateProvider.select(
        (s) => s.value?.attach ?? CheckoutAttachStatus.unknown,
      ),
    );

    final selectedId = _selectedTerminalId;
    if (selectedId != null) {
      final selected = tabs
          .where((t) => t.terminalId == selectedId)
          .firstOrNull;
      if (selected != null) {
        return _buildSelectedView(selected, tabs, terminalService, attach);
      }
      // Deleted or gone from the bridge: forget it after this frame, and show
      // the plain list meanwhile.
      if (key != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _updateTerminalUiFor(
            key,
            (s) => s.copyWith(clearSelectedTerminalId: true),
          ),
        );
      }
    }

    return Column(
      children: [
        _buildHeader(terminalService, tabs),
        Expanded(
          child: tabs.isEmpty
              ? _buildEmptyOrAttaching(terminalService, tabs, attach)
              : _buildList(tabs, terminalService),
        ),
      ],
    );
  }

  // ── Empty state ──────────────────────────────────────────────────────────

  /// The nothing-to-list surface, forked on whether the checkout has actually
  /// finished attaching.
  ///
  /// "No terminals" is a claim about the project, so it may only be made once
  /// the app knows there are none; while terminals are still being attached the
  /// same emptiness means nothing yet.
  Widget _buildEmptyOrAttaching(
    TerminalService service,
    List<TerminalTab> tabs,
    CheckoutAttachStatus attach,
  ) {
    switch (attach) {
      case CheckoutAttachStatus.attaching:
        return const AbEmptyState.compact(title: 'attaching terminals…');
      case CheckoutAttachStatus.failed:
        // Retry re-asks for the checkout's status, not one terminal's screen:
        // a checkout-wide failure means no `agent:status` ever arrived, so
        // there is no per-terminal pull to name. New Terminal stays — opening
        // a shell works whether or not the re-ask lands.
        return AbEmptyState.error(
          title: "Couldn't load terminals",
          subtitle: 'the agent has not answered yet',
          // Wrapped, not a Row: the empty state centres its action inside the
          // pane's own padding, and two buttons do not fit a split view at its
          // narrowest.
          action: Wrap(
            spacing: AbTokens.space8,
            alignment: WrapAlignment.center,
            children: [
              // No in-flight label: the re-ask clears the verdict
              // synchronously, so this arm is gone before one could paint.
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
              _newTerminalButton(service, tabs),
            ],
          ),
        );
      case CheckoutAttachStatus.unknown:
      case CheckoutAttachStatus.ready:
        return _buildEmptyState(service, tabs);
    }
  }

  Widget _buildEmptyState(TerminalService service, List<TerminalTab> tabs) {
    return AbEmptyState(
      icon: AbIcons.terminal,
      title: 'No terminals',
      subtitle: 'Open a shell to interact with your project',
      action: _newTerminalButton(service, tabs),
    );
  }

  Widget _newTerminalButton(TerminalService service, List<TerminalTab> tabs) {
    return AbButton(
      label: 'New Terminal',
      leading: AbIcon(AbIcons.add, size: 12, color: context.antgrid.accent),
      onTap: () => _createTerminal(service, tabs),
    );
  }

  Widget _buildHeader(TerminalService service, List<TerminalTab> tabs) {
    final atLimit = tabs.length >= _maxAdHocTerminals;
    return AbToolbar.panel(
      title: 'TERMINALS',
      actions: [
        AbIconButton(
          icon: AbIcons.add,
          tooltip: atLimit ? 'Max terminals reached' : 'New terminal',
          onTap: atLimit ? null : () => _createTerminal(service, tabs),
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
          icon: AbIcons.trash,
          tooltip: 'Delete',
          tone: AbIconButtonTone.danger,
          onTap: () => _deleteTerminal(service, tab.terminalId),
        ),
      ],
      divider: true,
      density: AbRowDensity.lg,
      onTap: () {
        // Focusing the terminal clears its unread badge.
        service.setActiveTerminal(tab.terminalId);
        _setSelectedTerminal(tab.terminalId);
      },
    );
  }

  // ── Selected view ────────────────────────────────────────────────────────

  Widget _buildSelectedView(
    TerminalTab selected,
    List<TerminalTab> all,
    TerminalService service,
    CheckoutAttachStatus attach,
  ) {
    final remaining = all
        .where((t) => t.terminalId != selected.terminalId)
        .toList();
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
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
                            selected.name,
                            style: AbTokens.monoStyle(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        AbIconButton(
                          icon: AbIcons.trash,
                          tooltip: 'Delete',
                          tone: AbIconButtonTone.danger,
                          onTap: () =>
                              _deleteTerminal(service, selected.terminalId),
                        ),
                        AbIconButton(
                          icon: AbIcons.close,
                          tooltip: 'Close terminal',
                          onTap: () => _setSelectedTerminal(null),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: TerminalViewWrapper(
                    // Switching rows mounts the next terminal's own view
                    // rather than retargeting this one's state at it.
                    key: ValueKey(selected.terminalId),
                    tab: selected,
                    terminalService: service,
                  ),
                ),
              ],
            ),
          ),
          const AbSeparator.horizontal(),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                // The whole list is the budget: the selected terminal counts
                // toward the cap too.
                _buildHeader(service, all),
                Expanded(
                  child: remaining.isEmpty
                      ? _buildEmptyOrAttaching(service, remaining, attach)
                      : _buildList(remaining, service),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
