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

final accountAgentsProvider = FutureProvider<List<InventoryAgent>>((ref) async {
  final api = ref.watch(accountAgentsApiProvider);
  return api.listAgents();
});
