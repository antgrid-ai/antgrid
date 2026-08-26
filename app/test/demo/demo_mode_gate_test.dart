// The demo flag is the sample project's whole lifetime: it selects the
// project, it decides whether the transport family hands out a DemoTransport,
// and flipping it off is what disposes that transport. These tests pin that
// loop, because a stale demo transport left warm is indistinguishable on
// screen from a real machine.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/demo_transport.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the demo is off until something enters it', () async {
    final container = await demoContainer();

    expect(container.read(demoModeProvider), isFalse);
    expect(container.read(selectedTargetProvider), isNull);
    expect(await demoTransportFrom(container), isNull);
  });

  test('entering selects the sample project and flips the flag', () async {
    final container = await demoContainer();

    enterDemoMode(container);

    expect(container.read(demoModeProvider), isTrue);
    expect(
      container.read(selectedTargetProvider),
      const LocalProject(kDemoProjectId),
    );
    expect(container.read(selectedRegistrationIdProvider), kDemoProjectId);
  });

  // No AbProject is registered here, so the relay and local branches below the
  // demo gate would both resolve to null. A DemoTransport coming back is proof
  // the gate sits above them — the branches that read the keychain.
  test('the sample project resolves to a DemoTransport', () async {
    final container = await demoContainer();
    enterDemoMode(container);

    final transport = await demoTransportFrom(container);

    expect(transport, isA<DemoTransport>());
    expect(transport!.isLocal, isTrue);
    expect(transport.currentState, TransportState.connected);
  });

  test('leaving disposes the transport and clears the focus', () async {
    final container = await demoContainer();
    // Kept alive across the flag flip so the family entry actually rebuilds
    // rather than sitting on a value nobody is watching.
    container.listen(
      agentTransportForProvider(kDemoProjectId),
      (_, _) {},
      fireImmediately: true,
    );
    enterDemoMode(container);
    final transport = await demoTransportFrom(container);
    expect(transport, isA<DemoTransport>());

    exitDemoMode(container);
    // The dispose is fired through `unawaited`, so let it land.
    await Future<void>.delayed(Duration.zero);

    expect(container.read(demoModeProvider), isFalse);
    expect(container.read(selectedTargetProvider), isNull);
    expect((transport! as DemoTransport).outbound.isClosed, isTrue);
    expect(await demoTransportFrom(container), isNull);
  });

  test('re-entering builds a fresh transport, not the disposed one', () async {
    final container = await demoContainer();
    container.listen(
      agentTransportForProvider(kDemoProjectId),
      (_, _) {},
      fireImmediately: true,
    );

    enterDemoMode(container);
    final first = await demoTransportFrom(container);
    exitDemoMode(container);
    await Future<void>.delayed(Duration.zero);
    enterDemoMode(container);
    final second = await demoTransportFrom(container);

    expect(second, isA<DemoTransport>());
    expect(identical(first, second), isFalse);
    expect(second!.currentState, TransportState.connected);
  });

  test('the demo id is the only one the gate answers for', () async {
    final container = await demoContainer();
    enterDemoMode(container);

    // Same shape as a real local project id, and no AbProject backs it.
    final other = await container.read(
      agentTransportForProvider('some-other-project').future,
    );

    expect(other, isNull);
  });

  test('isDemoEntryId also matches a relay-scoped key', () {
    expect(isDemoEntryId(kDemoProjectId), isTrue);
    expect(isDemoEntryId('machine-uuid.$kDemoProjectId'), isTrue);
    expect(isDemoEntryId('antgrid-demo-but-not'), isFalse);
    expect(isDemoEntryId(null), isFalse);
  });
}
