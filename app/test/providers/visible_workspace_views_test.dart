// Handler is a tab only while the focused session is armed (or has a question
// of its own waiting), on the desktop strip, the phone's bottom nav and the
// workspace menu alike — all three read this one list.
import 'dart:async';

import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

HandlerSessionState _armed(String terminalId) => HandlerSessionState(
  terminalId: terminalId,
  runState: HandlerRunState.watching,
  pendingEscalations: 0,
  armedAt: 1,
  goal: 'goal',
  backlog: const [],
  escalations: const [],
);

HandlerEscalation _question(String terminalId) => HandlerEscalation(
  escalationId: 'esc-$terminalId',
  terminalId: terminalId,
  question: 'q',
  reasoning: 'r',
  draftReply: 'd',
  urgency: 'normal',
  at: 1,
);

const _none = HandlerState.initial();

/// A container focused on `s1` whose Handler state is whatever [states]
/// emits last.
ProviderContainer _container(StreamController<HandlerState> states) {
  final container = ProviderContainer(
    overrides: [
      activeSessionIdProvider.overrideWith(() => ValueController('s1')),
      handlerStateProvider.overrideWith((ref) => states.stream),
    ],
  );
  addTearDown(container.dispose);
  container.listen(visibleWorkspaceViewsProvider, (_, _) {});
  return container;
}

Future<List<WorkspaceView>> _viewsFor(HandlerState state) async {
  final states = StreamController<HandlerState>();
  addTearDown(states.close);
  final container = _container(states);
  states.add(state);
  await Future<void>.delayed(Duration.zero);
  return container.read(visibleWorkspaceViewsProvider);
}

void main() {
  test('a session the Handler is not on has no Handler tab', () async {
    final views = await _viewsFor(_none);
    expect(views, isNot(contains(WorkspaceView.handler)));
    expect(views, containsAll([WorkspaceView.files, WorkspaceView.terminals]));
  });

  test('an armed session has it', () async {
    final views = await _viewsFor(_none.copyWith(sessions: {'s1': _armed('s1')}));
    expect(views, contains(WorkspaceView.handler));
  });

  test('a session with its own Handler question waiting has it', () async {
    final views = await _viewsFor(
      _none.copyWith(escalations: [_question('s1')]),
    );
    expect(views, contains(WorkspaceView.handler));
  });

  test('another session using Handler does not give this one the tab', () async {
    final views = await _viewsFor(
      _none.copyWith(
        sessions: {'s2': _armed('s2')},
        escalations: [_question('s2')],
      ),
    );
    expect(views, isNot(contains(WorkspaceView.handler)));
  });

  test('disarming hides it on the very next state', () async {
    final states = StreamController<HandlerState>();
    addTearDown(states.close);
    final container = _container(states);

    states.add(_none.copyWith(sessions: {'s1': _armed('s1')}));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(visibleWorkspaceViewsProvider),
      contains(WorkspaceView.handler),
    );

    states.add(_none);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(visibleWorkspaceViewsProvider),
      isNot(contains(WorkspaceView.handler)),
    );
  });
}
