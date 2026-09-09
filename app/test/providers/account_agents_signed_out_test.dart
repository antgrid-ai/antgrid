import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingAgentsApi implements AccountAgentsApi {
  _RecordingAgentsApi(this._agents);
  final List<InventoryAgent> _agents;
  int calls = 0;

  @override
  Future<List<InventoryAgent>> listAgents() async {
    calls++;
    return _agents;
  }

  @override
  String get baseUrl => 'http://localhost:8787';
  @override
  Future<String?> Function() get sessionCookieProvider => () async => null;
}

InventoryAgent _agent(String uuid) => InventoryAgent(
  deviceUuid: uuid,
  displayName: uuid,
  platform: 'windows',
  ed25519Pub: 'pub',
);

void main() {
  test('signed out resolves to an empty inventory without calling the API', () async {
    final api = _RecordingAgentsApi([_agent('machine-a')]);
    final container = ProviderContainer(
      overrides: [
        accountAgentsApiProvider.overrideWithValue(api),
        currentUserProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(accountAgentsProvider.future), isEmpty);
    expect(api.calls, 0);
  });

  test('a signed-out rebuild replaces the previous account inventory', () async {
    final api = _RecordingAgentsApi([_agent('machine-a')]);
    CurrentUser? user = CurrentUser(
      userId: 'u-1',
      email: 'a@b.test',
      tier: 'pro',
    );
    final container = ProviderContainer(
      overrides: [
        accountAgentsApiProvider.overrideWithValue(api),
        currentUserProvider.overrideWith((ref) => user),
      ],
    );
    addTearDown(container.dispose);
    // Mounted for the whole test, like `drawerEntriesProvider` watching it.
    final sub = container.listen(accountAgentsProvider, (_, _) {});
    addTearDown(sub.close);

    expect(await container.read(accountAgentsProvider.future), hasLength(1));

    // Sign out: the cookie is gone, so /account/me now resolves null.
    user = null;
    container.invalidate(currentUserProvider);
    await container.read(accountAgentsProvider.future);

    // `.value` — the read every UI surface makes. AsyncError and AsyncLoading
    // both RETAIN the previous value, so answering the signed-out case with a
    // throw would leave the drawer rendering the departed account's machines
    // for the rest of the process.
    expect(
      container.read(accountAgentsProvider).value,
      isEmpty,
      reason: 'the signed-out account inventory must not survive sign-out',
    );
  });
}
