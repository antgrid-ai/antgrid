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
  // Signed out ⇒ empty DATA, never a throw. `AsyncError` and `AsyncLoading`
  // both retain the previous value, so every `.value ?? const []` reader (the
  // drawer, the session picker, ConnectionSupervisor) would otherwise keep
  // serving the signed-out account's machines for the rest of the process.
  try {
    if (await ref.watch(currentUserProvider.future) == null) {
      return const <InventoryAgent>[];
    }
  } catch (_) {
    // A failed `/account/me` is not a sign-out signal, and its error is
    // STICKY: `currentUserProvider` never retries itself (noProviderRetry) and
    // is invalidated only by sign-in/sign-out, so rethrowing here would leave
    // every later `invalidate(accountAgentsProvider)` refresh re-throwing the
    // same cached failure with no way back once the network returns. Fall
    // through to the fetch, which carries the cookie and answers for itself —
    // and whose own failure keeps the last good inventory on screen.
  }
  return api.listAgents();
});
