import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/terminal_service.dart';
import '../models/terminal_models.dart';
import 'providers.dart';
import 'sessions.dart';
import 'ui_attention_providers.dart';

class _PrefetchFocus {
  TerminalService? service;
  void update(TerminalService? next, Object? visit, Set<String> candidates) {
    if (!identical(service, next)) service?.setPrefetchFocus(null, {});
    service = next;
    next?.setPrefetchFocus(visit, candidates);
  }
}

final _prefetchFocusProvider = Provider((ref) {
  final focus = _PrefetchFocus();
  ref.onDispose(() => focus.update(null, null, {}));
  return focus;
});

final terminalDemandBinderProvider = Provider<void>((ref) {
  final focus = ref.watch(_prefetchFocusProvider);
  final service = focusedCheckoutServicesOrNull(ref)?.terminalService;
  final sessionId = ref.watch(activeSessionIdProvider);
  final resumed =
      ref.watch(appLifecycleStateProvider) == AppLifecycleState.resumed;
  final workspace =
      ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.workspace;
  final tabs = ref.watch(terminalStateProvider).value?.tabs;
  final setupIds = {
    for (final session in ref.watch(freshSessionsStateProvider)?.sessions ?? [])
      ?session.setup?.terminalId,
  };
  focus.update(service, resumed && workspace ? sessionId : null, {
    for (final tab in tabs?.values ?? const <TerminalTab>[])
      if (tab.terminalId != 'agent' &&
          !tab.isAgent &&
          tab.type != 'service' &&
          !setupIds.contains(tab.terminalId))
        tab.terminalId,
  });
});
