import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../models/terminal_models.dart';
import 'providers.dart';
import 'sessions.dart';

/// The focused checkout's user-opened shells — what the Terminals panel lists.
///
/// Selected by EXCLUSION: a terminal typed neither `agent` nor `service` is a
/// user terminal. A checkout's `worktree.setup` transcript carries no type
/// either, so it is dropped by the id the bridge names for it
/// (`SessionSetup.terminalId`) — left in, a provisioning log would list as an
/// interactive tab with a Kill button over a live `bun install`.
final adHocTerminalsProvider = Provider<List<TerminalTab>>((ref) {
  final sessions =
      ref.watch(freshSessionsStateProvider)?.sessions ?? const <SessionEntry>[];
  final setupIds = {for (final s in sessions) ?s.setup?.terminalId};
  final tabs = ref.watch(terminalStateProvider).value?.tabs.values;
  if (tabs == null) return const [];
  return [
    for (final t in tabs)
      if (t.terminalId != 'agent' &&
          t.type != 'agent' &&
          t.type != 'service' &&
          !setupIds.contains(t.terminalId))
        t,
  ];
});
