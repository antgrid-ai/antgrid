// Tests for the per-projectId transport family introduced in Plan C / Task 1.
//
// Spawning a real local agent requires a full LocalAgentLauncher + bun runtime,
// which is out of scope for a unit test. We assert the only branch that's
// reachable without a running agent: when no [AbProject] matches the
// requested id, the family resolves to `null`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/agent_transport.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'agentTransportForProvider returns null when no project matches the id',
    () async {
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final container = ProviderContainer(overrides: stores.overrides);
      addTearDown(container.dispose);

      final transport = await container.read(
        agentTransportForProvider('unknown-id').future,
      );
      expect(transport, isNull);
    },
  );

  test(
    'legacy agentTransportProvider returns null when no project is selected',
    () async {
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final container = ProviderContainer(overrides: stores.overrides);
      addTearDown(container.dispose);

      // selectedTargetProvider defaults to null; with no paired agents in
      // the test store, the relay fallback also returns null.
      final transport = await container.read(agentTransportProvider.future);
      expect(transport, isNull);
    },
  );
}
