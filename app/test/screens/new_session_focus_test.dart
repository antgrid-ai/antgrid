// Pressing Start on the New Session canvas must land on the session it just
// created. Leaving that canvas REMOUNTS WorkspaceShell (AppShell swaps the
// whole route), and its bootstrap re-lists sessions and re-derives the focused
// one from the bridge's `lastUsedAt` order — which records ACTIVITY (a
// keystroke, an agent notification), not what the user opened, and which
// `session:focus` does not move. So a sibling session busy in the window
// between `session:start` and the list reply used to outrank the new session
// and take the focus, dropping the user back on the session they had just
// navigated away from.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/session_mode.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

/// Answers the session verbs the way the bridge does, ordering `session:list`
/// by `lastUsedAt` desc. [bumpOnStart] reproduces what makes the bug visible:
/// the previously-open session is touched (a keystroke, an OSC notification)
/// just after the new one starts, so it ranks first in the very list the
/// remount's bootstrap asks for.
class _BridgeLikeTransport extends FakeAgentTransport {
  _BridgeLikeTransport({this.bumpOnStart = false});

  final bool bumpOnStart;
  final List<Map<String, dynamic>> sessions = [];
  int clock = 1000;

  int lastUsedOf(String id) =>
      sessions.firstWhere((s) => s['id'] == id)['lastUsedAt'] as int;

  List<Map<String, dynamic>> _byRecency() {
    final l = [...sessions];
    l.sort(
      (a, b) => (b['lastUsedAt'] as int).compareTo(a['lastUsedAt'] as int),
    );
    return l;
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    await super.send(message, channel: channel);
    switch (message['type']) {
      case 'session:list':
        emit('session:list:result', {
          'requestId': message['requestId'],
          'sessions': _byRecency(),
        });
      case 'session:create':
        clock += 10;
        sessions.add(<String, dynamic>{
          'id': 'B',
          'name': message['name'] ?? 'B',
          'createdAt': clock,
          'lastUsedAt': clock,
          'archived': false,
          'running': false,
          'mode': message['mode'] ?? 'terminal',
          'tool': 'claude-code',
        });
        emit('session:updated', {'sessions': _byRecency()});
        emit('session:result', {
          'requestId': message['requestId'],
          'ok': true,
          'session': sessions.last,
        });
      case 'session:start':
        clock += 10;
        final e = sessions.firstWhere((s) => s['id'] == message['sessionId']);
        e['running'] = true;
        e['lastUsedAt'] = clock;
        if (bumpOnStart) {
          clock += 10;
          sessions.firstWhere((s) => s['id'] == 'A')['lastUsedAt'] = clock;
        }
        emit('session:updated', {'sessions': _byRecency()});
        emit('session:result', {
          'requestId': message['requestId'],
          'ok': true,
          'session': e,
        });
    }
  }
}

Map<String, dynamic> _oldSession() => <String, dynamic>{
  'id': 'A',
  'name': 'the session the user came from',
  'createdAt': 500,
  'lastUsedAt': 900,
  'archived': false,
  'running': true,
  'mode': 'terminal',
  'tool': 'claude-code',
};

void main() {
  Future<ProviderContainer> openProjectThenNewSession(
    WidgetTester tester,
    _BridgeLikeTransport t,
  ) async {
    final c = await pumpWorkspaceShell(tester, transport: (_) => t);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      c.read(activeSessionIdProvider),
      'A',
      reason: 'project open focuses the only session there is',
    );
    enterNewSession(c);
    await tester.pump();
    await tester.pump();
    return c;
  }

  /// Create + start, as the Start button does.
  Future<SessionEntry> startFrom(ProviderContainer c) async {
    final svc = c.read(sessionsServiceProvider);
    final created = await svc.create(name: 'new one', tool: 'claude-code');
    expect(created, isNotNull);
    expect(await svc.start(created!.id, initialPrompt: 'hi'), isNotNull);
    c.read(activeSessionIdProvider.notifier).set(created.id);
    return created;
  }

  testWidgets('the started session keeps focus though a sibling ranks first', (
    tester,
  ) async {
    final t = _BridgeLikeTransport(bumpOnStart: true)
      ..sessions.add(_oldSession());
    final c = await openProjectThenNewSession(tester, t);

    final created = await startFrom(c);
    // The tail of `startNewSession`, in order: the draft is consumed, the new
    // session is named for the remount, and only then does the canvas close.
    resetNewSessionForm(c);
    c.read(pendingActiveSessionIdProvider.notifier).set(created.id);
    leaveNewSession(c);

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // 'A' really is the most-recently-used row by now. The assertion is that
    // recency does not get to answer a question the user already answered.
    expect(t.lastUsedOf('A'), greaterThan(t.lastUsedOf('B')));
    expect(c.read(activeSessionIdProvider), 'B');
    await tester.pump(
      const Duration(seconds: 1),
    ); // cache write-through debounce
  });

  testWidgets('a focus already made survives a remount that carries no id', (
    tester,
  ) async {
    // The pending id is a single-use hand-off that every early return in the
    // bootstrap drops, so the default branch has to hold the line on its own.
    final t = _BridgeLikeTransport(bumpOnStart: true)
      ..sessions.add(_oldSession());
    final c = await openProjectThenNewSession(tester, t);

    await startFrom(c);
    resetNewSessionForm(c);
    leaveNewSession(c);

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(t.lastUsedOf('A'), greaterThan(t.lastUsedOf('B')));
    expect(c.read(activeSessionIdProvider), 'B');
    await tester.pump(const Duration(seconds: 1));
  });

  test('mode and checkout resolve while the live session row is absent', () {
    // `freshSessionsStateProvider` reports null for the whole window in which
    // the list re-subscribes. Reading the mode as null there is what dropped a
    // chat session onto the terminal view (which then fell back to whatever
    // other session's tab was live), and reading the checkout as 'main' aimed
    // every checkout-scoped verb at the wrong worktree.
    final c = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWith((ref) => 'P'),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
        cachedSessionsProvider('P').overrideWith(
          (ref) => const [
            SessionEntry(
              id: 'B',
              name: 'chat one',
              createdAt: 1,
              lastUsedAt: 2,
              archived: false,
              running: false,
              mode: 'chat',
              checkoutId: 'wt1',
              checkoutKind: 'managed-worktree',
            ),
          ],
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(activeSessionIdProvider.notifier).set('B');

    expect(c.read(activeSessionProvider), isNull);
    expect(c.read(activeSessionModeProvider), 'chat');
    expect(c.read(focusedCheckoutIdProvider), 'wt1');
  });
}
