import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/workspace_view.dart';
import 'agent_transport.dart';
import 'sessions.dart';

typedef SessionUiKey = ({String entryId, String sessionId});

class SessionWorkspaceState {
  const SessionWorkspaceState({
    this.initialized = false,
    this.selectedView = WorkspaceView.files,
    this.panelMode,
    this.mobilePage = 0,
    this.tabletContextOpen = false,
    this.tabletContextExpanded = false,
    this.pinnedTerminalId,
    this.pushedTerminalId,
  });

  final bool initialized;
  final WorkspaceView selectedView;
  final String? panelMode;
  final int mobilePage;
  final bool tabletContextOpen;
  final bool tabletContextExpanded;
  final String? pinnedTerminalId;
  final String? pushedTerminalId;

  SessionWorkspaceState copyWith({
    bool? initialized,
    WorkspaceView? selectedView,
    String? panelMode,
    int? mobilePage,
    bool? tabletContextOpen,
    bool? tabletContextExpanded,
    String? pinnedTerminalId,
    bool clearPinnedTerminalId = false,
    String? pushedTerminalId,
    bool clearPushedTerminalId = false,
  }) => SessionWorkspaceState(
    initialized: initialized ?? this.initialized,
    selectedView: selectedView ?? this.selectedView,
    panelMode: panelMode ?? this.panelMode,
    mobilePage: mobilePage ?? this.mobilePage,
    tabletContextOpen: tabletContextOpen ?? this.tabletContextOpen,
    tabletContextExpanded: tabletContextExpanded ?? this.tabletContextExpanded,
    pinnedTerminalId: clearPinnedTerminalId
        ? null
        : (pinnedTerminalId ?? this.pinnedTerminalId),
    pushedTerminalId: clearPushedTerminalId
        ? null
        : (pushedTerminalId ?? this.pushedTerminalId),
  );
}

class SessionWorkspaceController extends Notifier<SessionWorkspaceState> {
  SessionWorkspaceController(this.key);

  final SessionUiKey key;

  @override
  SessionWorkspaceState build() => const SessionWorkspaceState();

  void update(SessionWorkspaceState Function(SessionWorkspaceState) change) {
    state = change(state);
  }
}

final sessionWorkspaceStateProvider =
    NotifierProvider.family<
      SessionWorkspaceController,
      SessionWorkspaceState,
      SessionUiKey
    >(SessionWorkspaceController.new);

final activeSessionUiKeyProvider = Provider<SessionUiKey?>((ref) {
  final entryId = ref.watch(selectedRegistrationIdProvider);
  final sessionId = ref.watch(activeSessionIdProvider);
  if (entryId == null || sessionId == null) return null;
  return (entryId: entryId, sessionId: sessionId);
});

void clearSessionWorkspaceState(
  ProviderContainer ref,
  String entryId,
  String sessionId,
) {
  ref.invalidate(
    sessionWorkspaceStateProvider((entryId: entryId, sessionId: sessionId)),
  );
}
