import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../analytics/events.dart';
import '../config/environment.dart';
import '../services/account_api.dart';
import '../services/auth_service.dart';
import '../services/devices_api.dart' show DeviceCapInfo;
import 'analytics.dart';
import 'provider_retry.dart';
import 'value_controller.dart';

/// License/account API base URL. Precedence: a `LICENSE_API_URL` dart-define
/// wins; otherwise the build-mode default (release → prod, debug/profile →
/// staging). For the local full-stack loop pass
/// `--dart-define=LICENSE_API_URL=http://localhost:8787`.
final licenseApiUrlProvider = Provider<String>((ref) {
  const fromEnv = String.fromEnvironment('LICENSE_API_URL');
  return fromEnv.isNotEmpty ? fromEnv : AppEnvironment.licenseApiUrl;
});

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(
    licenseApiUrl: ref.watch(licenseApiUrlProvider),
    storage: SecureAuthStorage(),
  );
});

final accountApiProvider = Provider<AccountApi>((ref) {
  final auth = ref.read(authServiceProvider);
  return AccountApi(
    licenseApiUrl: ref.read(licenseApiUrlProvider),
    cookieProvider: () => auth.storage.readCookie(),
  );
});

// retry: a transient /account/me failure must surface to awaiting consumers
// (best-effort provisioning in resolveDeviceRecord, the sign-in gate) so they
// can fall back — not be retried behind their back, which under Riverpod 3's
// default would leave `.future` pending until dispose. See provider_retry.dart.
final currentUserProvider = FutureProvider<CurrentUser?>((ref) async {
  return ref.watch(authServiceProvider).fetchCurrentUser();
}, retry: noProviderRetry);

/// Stored-cookie presence — a synchronous, network-free signal that we *think*
/// we're signed in. Used as the optimistic fallback when [currentUserProvider]
/// is loading (cold start) or errored (offline) so we don't bounce signed-in
/// users to the sign-in screen during a transient network failure.
final hasStoredSessionProvider = FutureProvider<bool>((ref) async {
  final cookie = await ref.watch(authServiceProvider).storage.readCookie();
  return cookie != null && cookie.isNotEmpty;
});

/// Tri-state sign-in status:
///   - `null` ⇒ unknown (loading, no cached cookie either) — render splash.
///   - `true` ⇒ signed in (network confirmed) OR loading/errored but a cookie
///              is cached (optimistic; revalidates on next success).
///   - `false` ⇒ definitively signed out (server returned null user).
final signedInProvider = Provider<bool?>((ref) {
  final user = ref.watch(currentUserProvider);
  return user.when(
    data: (u) => u != null,
    loading: () => ref.watch(hasStoredSessionProvider).value,
    error: (_, _) {
      final cached = ref.watch(hasStoredSessionProvider).value;
      if (cached == true) return true;
      if (cached == false) return false;
      return null;
    },
  );
});

/// True when the signed-in user needs Pro for mobile/relay features.
bool requiresProForMobile(String? tier) => tier == null || tier == 'free';

Future<void> openUpgradeInBrowser(
  ProviderContainer ref, {
  String? planId,
}) async {
  ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.checkoutOpened);
  final base = ref.read(licenseApiUrlProvider).replaceAll(RegExp(r'/+$'), '');
  final path = planId == null ? '/upgrade' : '/checkout?planId=$planId';
  final uri = Uri.parse('$base$path');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Non-null when device provisioning was rejected by the fair-use device cap
/// (HTTP 402 `DEVICE_CAP`). Carries the limit + already-registered devices so
/// the remediation UI can offer to revoke one. This is NOT a paid gate — the
/// remedy is to remove a device, never to upgrade — so it must not route to the
/// upgrade screen. Cleared on success, sign-out, and dialog dismissal.
final deviceCapProvider =
    NotifierProvider<ValueController<DeviceCapInfo?>, DeviceCapInfo?>(
      () => ValueController(null),
    );
