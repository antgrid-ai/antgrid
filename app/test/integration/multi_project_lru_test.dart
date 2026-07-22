// Widget-level multi-project LRU integration coverage. The pure policy is
// covered by `test/project/lru_policy_test.dart` and the registry mechanism
// by `test/project/registry_lru_test.dart`; this test wires the two through
// the real Riverpod providers (with a stubbed session factory) to confirm
// they behave correctly end-to-end at the provider boundary.
//
// Note: we track evictions via the registry's `onEvict` callback rather than
// the session's `onClose`, because the `projectSessionProvider` family is
// `autoDispose` — once `container.read(...future)` resolves with no live
// listener, the entry is torn down and `session.close()` fires regardless of
// whether the registry actually evicted it. `onEvict` only fires for true
// LRU evictions.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

ProviderContainer _buildContainer({
  required int warmCap,
  required List<String> evicted,
}) {
  late ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      projectSessionFactoryProvider.overrideWithValue((
        Ref ref,
        String projectId,
      ) async {
        final t = FakeAgentTransport();
        final cache = await CachedSessionsStore.open();
        return ProjectSession(
          projectId: projectId,
          transport: t,
          mode: ProjectSessionMode.local,
          cachedSessionsStore: cache,
          onClose: () async {
            await t.dispose();
          },
        );
      }),
      projectSessionRegistryProvider.overrideWith(
        () => ProjectSessionRegistryController(
          ProjectSessionRegistry(
            localCap: warmCap,
            relayCap: warmCap,
            onEvict: (id) async {
              evicted.add(id);
              container.invalidate(projectSessionProvider(id));
            },
          ),
        ),
      ),
    ],
  );
  return container;
}

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  test('opening 11 projects evicts the oldest', () async {
    final evicted = <String>[];
    final container = _buildContainer(warmCap: 10, evicted: evicted);
    addTearDown(container.dispose);

    for (var i = 0; i < 11; i++) {
      await container.read(projectSessionProvider('p$i').future);
      // Tiny delay so DateTime.now() timestamps strictly increase per touch.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final registry = container
        .read(projectSessionRegistryProvider.notifier)
        .registry;
    expect(registry.openProjects, hasLength(10));
    expect(registry.openProjects, isNot(contains('p0')));
    expect(evicted, ['p0']);
  });
}
