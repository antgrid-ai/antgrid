// The Handler workspace tab answers for the session in focus, the way the
// files and git tabs answer for the checkout in focus. These pin the two
// providers that make that true: the state the tab renders, and the count it
// advertises — which reads THROUGH that same state, so the two can never
// disagree about what the tab holds.
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

HandlerSessionState _session(String terminalId, {required int pending}) =>
    HandlerSessionState(
      terminalId: terminalId,
      runState: pending > 0
          ? HandlerRunState.needsYou
          : HandlerRunState.watching,
      pendingEscalations: pending,
      armedAt: 1,
      goal: 'ship it',
      backlog: const [],
      escalations: const [],
    );

final _twoSessions = HandlerState.initial().copyWith(
  sessions: {'t1': _session('t1', pending: 1), 't2': _session('t2', pending: 2)},
);

ProviderContainer _container({String? focused}) {
  final container = ProviderContainer(
    overrides: [
      activeSessionIdProvider.overrideWith(() => ValueController(focused)),
      handlerStateProvider.overrideWith((ref) => Stream.value(_twoSessions)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Activated with `listen`, never a bare `read`: in riverpod 3 a read closes
/// its subscription immediately, and the stream is then disposed mid-load with
/// nothing to emit.
Future<void> _settle(ProviderContainer c) async {
  c.listen(handlerStateProvider, (_, _) {});
  await c.read(handlerStateProvider.future);
}

void main() {
  group('focusedSessionHandlerStateProvider', () {
    test('renders the focused session and nothing beside it', () async {
      final c = _container(focused: 't2');
      await _settle(c);
      final state = c.read(focusedSessionHandlerStateProvider);
      expect(state.sessions.keys, ['t2']);
      expect(state.pendingEscalations, 2);
    });

    test('is empty before a session resolves', () async {
      // The service is still constructing after a project switch, and an empty
      // tab is the honest answer for the frame that gap lasts.
      final c = ProviderContainer(
        overrides: [
          activeSessionIdProvider.overrideWith(() => ValueController('t1')),
          handlerStateProvider.overrideWith(
            (ref) => const Stream<HandlerState>.empty(),
          ),
        ],
      );
      addTearDown(c.dispose);
      final state = c.read(focusedSessionHandlerStateProvider);
      expect(state.anyArmed, isFalse);
      expect(state.sessions, isEmpty);
      expect(state.escalations, isEmpty);
      expect(state.pendingEscalations, 0);
      // Read too: the badge derives from this state, so a loading frame that
      // threw would take the whole tab strip with it.
      expect(
        c.read(workspaceBadgesProvider),
        isNot(contains(WorkspaceView.handler)),
      );
    });
  });

  group('workspaceBadgesProvider', () {
    test('counts the focused session, not the project', () async {
      final c = _container(focused: 't1');
      await _settle(c);
      // 3 is the project-wide total; a badge carrying it would send the user to
      // a tab narrowed past two of the three.
      expect(c.read(workspaceBadgesProvider)[WorkspaceView.handler], 1);
    });

    test('drops the badge for a focused session with nothing pending', () async {
      // The quiet session is PRESENT in the fixture: an absent id answers 0 by
      // short-circuiting the lookup, so it would pass over a rule that badged
      // every session it could actually find.
      final c = ProviderContainer(
        overrides: [
          activeSessionIdProvider.overrideWith(() => ValueController('t3')),
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(
              _twoSessions.copyWith(
                sessions: {
                  ..._twoSessions.sessions,
                  't3': _session('t3', pending: 0),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await _settle(c);
      expect(
        c.read(workspaceBadgesProvider),
        isNot(contains(WorkspaceView.handler)),
      );
    });

    test('with no session focused there is nothing to badge', () async {
      final c = _container();
      await _settle(c);
      expect(
        c.read(workspaceBadgesProvider),
        isNot(contains(WorkspaceView.handler)),
      );
    });
  });
}
