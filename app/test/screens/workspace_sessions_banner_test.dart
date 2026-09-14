// A transport that drops while the bootstrap is asking for the session list is
// a routine event — an owner takeover, a host restart, a relay stream rebind —
// and it heals itself: `SessionsService`'s `sessions:list` hydrator re-runs on
// re-establish. The banner it used to latch did NOT heal, because nothing
// clears that provider but a user tap, so a fully recovered project kept
// offering "switch projects and back to retry" over a panel that had already
// reloaded. Observed live on 2026-09-08 after taking the loopback owner socket
// away from the app and giving it back.
import 'package:antgrid/providers/relay_error_banner.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show TransportState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  Map<String, dynamic> session() => {
    'id': 'session-1',
    'name': 'Session 1',
    'createdAt': 0,
    'lastUsedAt': 0,
    'archived': false,
    'running': true,
    'mode': 'terminal',
  };

  testWidgets('a transport drop mid-load latches no sessions banner', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
    );
    await tester.pump();
    await tester.pump();

    // The bootstrap is now awaiting its `session:list`. Drop the transport
    // underneath it: the pending registry fails the reply immediately with
    // SessionDownException rather than waiting out its own timeout.
    transport.emitState(TransportState.disconnected);
    await tester.pump();
    await tester.pump();

    expect(
      container.read(relayErrorBannerProvider),
      isNull,
      reason: 'a self-healing transport drop must not latch a banner that '
          'only a user tap can clear',
    );
  });

  testWidgets('a later successful load retires a latched sessions banner', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
    );
    await tester.pump();
    await tester.pump();

    // Whatever latched it — this stands in for any failure path that does.
    container
        .read(relayErrorBannerProvider.notifier)
        .set(const RelayErrorBanner('SESSIONS', 'Couldn\'t load ...'));
    expect(container.read(relayErrorBannerProvider), isNotNull);

    // Answer the bootstrap's own request; the shell then reaches the clear.
    final list = transport.sent.lastWhere((m) => m['type'] == 'session:list');
    transport.emit('session:list:result', {
      'requestId': list['requestId'],
      'sessions': [session()],
    });
    await tester.pump();
    await tester.pump();

    expect(
      container.read(relayErrorBannerProvider),
      isNull,
      reason: 'the panel reloaded, so the notice about it failing to load '
          'must go with it',
    );

    // The bootstrap focuses the session it picked and nothing answers that
    // here; drain its pending-reply bound so no timer outlives the tree.
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('a non-sessions notice survives a successful load', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpWorkspaceShell(
      tester,
      transport: (_) => transport,
    );
    await tester.pump();
    await tester.pump();

    // A license/auth notice says nothing about the session list, so a session
    // list that loads says nothing about it either.
    container
        .read(relayErrorBannerProvider.notifier)
        .set(const RelayErrorBanner('LICENSE_EXPIRED', 'Subscription lapsed'));

    final list = transport.sent.lastWhere((m) => m['type'] == 'session:list');
    transport.emit('session:list:result', {
      'requestId': list['requestId'],
      'sessions': [session()],
    });
    await tester.pump();
    await tester.pump();

    expect(container.read(relayErrorBannerProvider)?.code, 'LICENSE_EXPIRED');

    await tester.pump(const Duration(seconds: 20));
  });
}
