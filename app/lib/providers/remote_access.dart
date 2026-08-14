import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../services/devices_api.dart';
import 'control_plane.dart';
import 'device_provisioning.dart';

/// A loopback [HostControlClient] bound to the live machine host (port+token
/// from `ensureHost`). Overridden in tests with a fake-backed client. Disposed
/// with the provider scope.
final hostControlClientProvider = FutureProvider<HostControlClient>((
  ref,
) async {
  final host = await ref.read(hostControllerProvider).ensureHost();
  final client = HostControlClient(port: host.controlPort, token: host.token);
  ref.onDispose(client.close);
  return client;
});

/// Runs [op] against the loopback client, dropping the cached client when the
/// POST could not reach the host at all.
///
/// [hostRestartRebindProvider] already invalidates on a host this app saw
/// replaced; this covers what that cannot see — a host swapped out from under
/// us, or an `up` whose generation never moved. Without it the panel's Retry
/// rebuilds the failing provider around the SAME dead client, so a stale port
/// is unrecoverable short of an app restart.
Future<T> _viaHost<T>(
  Ref ref,
  Future<T> Function(HostControlClient c) op,
) async {
  final HostControlClient client;
  try {
    client = await ref.read(hostControlClientProvider.future);
  } catch (_) {
    // `ensureHost` threw, and Riverpod caches that AsyncError: rebuilding THIS
    // provider re-reads the same failure, so the panel's Retry would be dead
    // for the rest of the launch — the exact state the invalidate below exists
    // to prevent, one layer up.
    ref.invalidate(hostControlClientProvider);
    rethrow;
  }
  try {
    return await op(client);
  } on HostControlException catch (e) {
    if (e.code == 'TRANSPORT') ref.invalidate(hostControlClientProvider);
    rethrow;
  }
}

/// Loads the roster of devices that have connected to this machine and mutates
/// it over the loopback control plane (the bridge is the single writer). Every
/// mutation refreshes from the bridge so the UI reflects the authoritative
/// state.
final remoteDevicesProvider =
    AsyncNotifierProvider<RemoteDevicesNotifier, PhonesList>(
      RemoteDevicesNotifier.new,
    );

class RemoteDevicesNotifier extends AsyncNotifier<PhonesList> {
  @override
  Future<PhonesList> build() async => _viaHost(ref, (c) => c.phonesList());

  Future<void> _mutate(Future<void> Function(HostControlClient c) op) async {
    // Retain the current data under the loading flag so a toggle/refresh does
    // not blank the whole hub to a spinner — the screen reads this via
    // `when(skipLoadingOnReload: true)` and keeps the phone list on screen.
    // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
    state = const AsyncLoading<PhonesList>().copyWithPrevious(state);
    try {
      state = AsyncData(
        await _viaHost(ref, (c) async {
          await op(c);
          return c.phonesList();
        }),
      );
    } catch (e, st) {
      // Retain the last-known list under the error too: `hasError` still fires
      // the hub screen's `when(error:)`, but consumers that render from
      // value (the agent-panel toggle) keep showing the prior state and
      // surface the failure separately instead of vanishing.
      // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
      state = AsyncError<PhonesList>(e, st).copyWithPrevious(state);
    }
  }

  Future<void> unpair({required String phonePubkey}) =>
      _mutate((c) => c.phonesUnpair(phonePubkey: phonePubkey));
}

/// The account's devices keyed by the id the BRIDGE knows them by
/// (`PairedPhone.phoneDeviceId` == the account device's `device_id`, which is
/// what `/account/devices/me/peers` hands the bridge at admission).
///
/// This join is what lets a roster row offer a real remedy. Clearing the local
/// record is not one: admission is account trust, so the device re-creates its
/// row on the next connect. Only revoking the account device — which deletes
/// its OAuth client and kicks it off the relay — actually cuts it off.
///
/// Empty while signed out or unreachable; a row with no match is a device the
/// account no longer has, so there is nothing left to revoke.
final accountDevicesByBridgeIdProvider =
    FutureProvider<Map<String, DeviceSummary>>((ref) async {
      final devices = await ref.watch(devicesApiProvider).list();
      return {for (final d in devices) d.deviceId: d};
    });

final remoteAccessPolicyProvider =
    AsyncNotifierProvider<RemoteAccessPolicyNotifier, RemoteAccessPolicy>(
      RemoteAccessPolicyNotifier.new,
    );

class RemoteAccessPolicyNotifier extends AsyncNotifier<RemoteAccessPolicy> {
  @override
  Future<RemoteAccessPolicy> build() async =>
      _viaHost(ref, (c) => c.remoteAccessGet());

  Future<void> _mutate(
    Future<RemoteAccessPolicy> Function(HostControlClient c) op,
  ) async {
    // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
    state = const AsyncLoading<RemoteAccessPolicy>().copyWithPrevious(state);
    try {
      state = AsyncData(await _viaHost(ref, op));
    } catch (e, st) {
      // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
      state = AsyncError<RemoteAccessPolicy>(e, st).copyWithPrevious(state);
    }
  }

  /// Flip the machine-wide switch. The bridge's response is the resulting
  /// state, so the notifier never has to guess what landed.
  Future<void> setEnabled(bool enabled) =>
      _mutate((c) => c.remoteAccessSet(enabled));
}
