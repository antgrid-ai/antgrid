import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import 'control_plane.dart';

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

/// Loads the paired-phone roster for the desktop hub and mutates it over the
/// loopback control plane (the bridge is the single writer). Every mutation
/// refreshes from the bridge so the UI reflects the authoritative state.
final mobileDevicesHubProvider =
    AsyncNotifierProvider<MobileDevicesHubNotifier, PhonesList>(
      MobileDevicesHubNotifier.new,
    );

class MobileDevicesHubNotifier extends AsyncNotifier<PhonesList> {
  Future<HostControlClient> get _client =>
      ref.read(hostControlClientProvider.future);

  @override
  Future<PhonesList> build() async => (await _client).phonesList();

  Future<void> _mutate(Future<void> Function(HostControlClient c) op) async {
    // Retain the current data under the loading flag so a toggle/refresh does
    // not blank the whole hub to a spinner — the screen reads this via
    // `when(skipLoadingOnReload: true)` and keeps the phone list on screen.
    // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
    state = const AsyncLoading<PhonesList>().copyWithPrevious(state);
    try {
      final c = await _client;
      await op(c);
      state = AsyncData(await c.phonesList());
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

final mobileAccessPolicyProvider =
    AsyncNotifierProvider<MobileAccessPolicyNotifier, MobileAccessPolicy>(
      MobileAccessPolicyNotifier.new,
    );

class MobileAccessPolicyNotifier extends AsyncNotifier<MobileAccessPolicy> {
  Future<HostControlClient> get _client =>
      ref.read(hostControlClientProvider.future);

  @override
  Future<MobileAccessPolicy> build() async => (await _client).mobileAccessGet();

  Future<void> _mutate(
    Future<MobileAccessPolicy> Function(HostControlClient c) op,
  ) async {
    // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
    state = const AsyncLoading<MobileAccessPolicy>().copyWithPrevious(state);
    try {
      final c = await _client;
      state = AsyncData(await op(c));
    } catch (e, st) {
      // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
      state = AsyncError<MobileAccessPolicy>(e, st).copyWithPrevious(state);
    }
  }

  /// Flip the machine-wide switch. The bridge's response is the resulting
  /// state, so the notifier never has to guess what landed.
  Future<void> setEnabled(bool enabled) =>
      _mutate((c) => c.mobileAccessSet(enabled));
}
