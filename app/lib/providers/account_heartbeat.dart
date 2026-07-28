import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/account_heartbeat.dart';
import '../services/auth_service.dart' show CurrentUser;
import 'auth.dart';
import 'device_provisioning.dart';
import 'providers.dart';

/// How often the app beats while signed in. Desktop machines get `lastSeenAt`
/// for free via the bridge's opportunistic heartbeat (`host-server.ts`
/// `pushHeartbeat`, fired on relay auth); the app has no equivalent
/// connection-driven trigger, so it beats on a plain interval instead. Short
/// enough that the very first beat — skipped if it races
/// [postSignInProvisioningProvider]'s keychain write — is caught up quickly.
const _heartbeatInterval = Duration(minutes: 5);

/// Keeps this device's `lastSeenAt` fresh in the account Devices dashboard
/// (`web/src/ui/devices.tsx`) so a phone/app row shows real recency instead
/// of never checking in. Activated once for the app's lifetime via
/// `container.listen` in `main.dart` — see that call site for why `listen`
/// (not a bare `read`) is required to keep this provider's own
/// `ref.listen(currentUserProvider, ...)` alive.
final accountHeartbeatProvider = Provider<void>((ref) {
  Timer? timer;

  Future<void> beat() async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return;
    final store = ref.read(keychainDeviceStoreProvider);
    final record = await store.readIfMatchesUser(user.userId);
    if (record == null) return;
    if (!ref.mounted) return;
    final minter = await ref.read(licenseTokenMinterProvider.future);
    if (minter == null || !ref.mounted) return;
    String token;
    try {
      token = minter.getToken() ?? await minter.mint();
    } catch (_) {
      return;
    }
    if (!ref.mounted) return;
    await sendAccountHeartbeat(
      licenseApiUrl: ref.read(licenseApiUrlProvider),
      token: token,
      deviceUuid: record.deviceUuid,
    );
  }

  ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
    timer?.cancel();
    timer = null;
    if (next.value == null) return;
    unawaited(beat());
    timer = Timer.periodic(_heartbeatInterval, (_) => unawaited(beat()));
  }, fireImmediately: true);

  ref.onDispose(() => timer?.cancel());
});
