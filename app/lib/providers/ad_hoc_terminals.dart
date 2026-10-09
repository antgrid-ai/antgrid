import 'package:flutter/foundation.dart' show listEquals;
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
///
/// A notifier so an upstream emission that leaves the same tabs listed keeps
/// the previous list: a status or session update re-emits the state, and a
/// fresh list each time would repaint the whole panel for nothing.
final adHocTerminalsProvider =
    NotifierProvider<AdHocTerminalsNotifier, List<TerminalTab>>(
      AdHocTerminalsNotifier.new,
    );

class AdHocTerminalsNotifier extends Notifier<List<TerminalTab>> {
  // A plain field, not stateOrNull: reading state from inside build() flushes
  // the element it is building.
  List<TerminalTab>? _last;

  @override
  List<TerminalTab> build() {
    final next = _select();
    final last = _last;
    if (last != null && listEquals(last, next)) return last;
    return _last = next;
  }

  List<TerminalTab> _select() {
    final sessions =
        ref.watch(freshSessionsStateProvider)?.sessions ??
        const <SessionEntry>[];
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
  }
}
