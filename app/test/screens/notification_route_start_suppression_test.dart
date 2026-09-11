// Reusing the pending-session-id handover for a notification tap is not a pure
// focus move: its drain auto-starts a stopped session, because a Recent-list
// tap means "resume this". A notification tap means "show me what happened", and
// restarting an agent the user let finish spends tokens nobody asked for — so
// the suppressor NAMES the queued id it speaks for. Five other sites queue an id
// without knowing it exists, and the bootstrap can return early past the point
// one is set, so a bare flag would eventually answer for one of theirs.
import 'package:antgrid/providers/relay_error_banner.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

Map<String, dynamic> _stopped(String id) => {
  'id': id,
  'name': id,
  'createdAt': 0,
  'lastUsedAt': 0,
  'archived': false,
  'running': false,
  'mode': 'terminal',
};

/// Answers the bootstrap's OWN `session:list` — the transport's hydrator sends
/// one too, with no pending reply behind it.
void _answerList(FakeAgentTransport transport, String sessionId) {
  final list = transport.sent.lastWhere((m) => m['type'] == 'session:list');
  transport.emit('session:list:result', {
    'requestId': list['requestId'],
    'sessions': [_stopped(sessionId)],
  });
}

void main() {
  testWidgets('a suppressed pending id focuses without starting', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
      extraOverrides: [
        pendingActiveSessionIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
        pendingSessionStartSuppressedIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    _answerList(transport, 'session-1');
    await tester.pump();

    expect(container.read(activeSessionIdProvider), 'session-1');
    expect(transport.sent.where((m) => m['type'] == 'session:start'), isEmpty);
    // Cleared with the id it rode in on, so the next queued pick starts from
    // the Recent-list default rather than inheriting this one.
    expect(container.read(pendingSessionStartSuppressedIdProvider), isNull);
    expect(container.read(pendingActiveSessionIdProvider), isNull);

    // The list result schedules the session cache's debounced flush; leaving it
    // pending fails the test on the binding's timer check.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an unsuppressed pending id still starts the session', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
      extraOverrides: [
        pendingActiveSessionIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    _answerList(transport, 'session-1');
    await tester.pump();

    expect(container.read(activeSessionIdProvider), 'session-1');
    expect(
      transport.sent.where((m) => m['type'] == 'session:start'),
      isNotEmpty,
      reason: 'a Recent-list tap on a stopped session means resume it',
    );

    // The start is never answered; past the service's 15s bound it fails, and
    // the detached bootstrap must survive that (see
    // workspace_shell_bootstrap_timeout_test.dart).
    await tester.pump(const Duration(seconds: 20));
  });

  // The named session is gone from the list, so the pending branch falls
  // THROUGH to the default pick — and that pick auto-starts. A tap asking to
  // see a session the bridge has since deleted must not resume an unrelated
  // agent instead: it is the same token spend, arrived at by the path where the
  // user's intent is furthest from a resume.
  testWidgets('a suppressed pending id that no longer exists starts nothing', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
      extraOverrides: [
        pendingActiveSessionIdProvider.overrideWith(
          () => ValueController('session-gone'),
        ),
        pendingSessionStartSuppressedIdProvider.overrideWith(
          () => ValueController('session-gone'),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    _answerList(transport, 'session-1');
    await tester.pump();

    expect(container.read(activeSessionIdProvider), 'session-1');
    expect(transport.sent.where((m) => m['type'] == 'session:start'), isEmpty);

    await tester.pump(const Duration(seconds: 1));
  });

  // The one early return that drops a queued id without a drain having
  // consumed it. Left set, the suppressor outlives the run that wrote it and
  // eats the next Recent-list tap on that same session.
  testWidgets('a failed session list clears the suppressor with the id', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
      extraOverrides: [
        pendingActiveSessionIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
        pendingSessionStartSuppressedIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    // Never answered: past the service's 15s pending-reply bound the request
    // fails, which is the branch that raises the SESSIONS banner.
    await tester.pump(const Duration(seconds: 20));

    expect(container.read(relayErrorBannerProvider)?.code, 'SESSIONS');
    expect(container.read(pendingActiveSessionIdProvider), isNull);
    expect(container.read(pendingSessionStartSuppressedIdProvider), isNull);
  });

  // The one a bare flag could not survive: a suppressor left behind by a run
  // that returned early, meeting the NEXT tap's queued id. It names a session
  // nobody is resolving, so it must not speak for this one.
  testWidgets('a suppressor naming another session does not suppress', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
      extraOverrides: [
        pendingActiveSessionIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
        pendingSessionStartSuppressedIdProvider.overrideWith(
          () => ValueController('a-session-nobody-is-resolving'),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    _answerList(transport, 'session-1');
    await tester.pump();

    expect(container.read(activeSessionIdProvider), 'session-1');
    expect(
      transport.sent.where((m) => m['type'] == 'session:start'),
      isNotEmpty,
      reason: 'a stale suppressor must not eat a Recent-list tap resume',
    );
    expect(container.read(pendingSessionStartSuppressedIdProvider), isNull);

    await tester.pump(const Duration(seconds: 20));
  });
}
