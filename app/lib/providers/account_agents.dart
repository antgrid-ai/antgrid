import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/account_agents_api.dart';
import 'auth.dart';

final accountAgentsApiProvider = Provider<AccountAgentsApi>((ref) {
  final auth = ref.watch(authServiceProvider);
  return AccountAgentsApi(
    baseUrl: ref.watch(licenseApiUrlProvider),
    sessionCookieProvider: () => auth.storage.readCookie(),
  );
});

/// The account's machine inventory.
///
/// NOT demo-gated here, deliberately, even though every UI reader is: a real
/// machine can stay warm behind the demo on desktop, and `ConnectionSupervisor`
/// resolves its dial coordinates through this provider — answering it empty
/// would silently demote that machine to its cached `RecentAgent` pin for the
/// demo's whole lifetime, which is a dead dial for any machine that has since
/// moved relay or re-provisioned its key. Readers that must not reach the
/// keychain from inside the demo gate themselves; see `demo/demo_identity.dart`.
final accountAgentsProvider = FutureProvider<List<InventoryAgent>>((ref) async {
  final api = ref.watch(accountAgentsApiProvider);
  return api.listAgents();
});
