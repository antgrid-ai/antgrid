import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../services/screen_share_service.dart';
import 'remote_access.dart';

/// The machine's screen-control switch, read and written over the loopback
/// control plane (the bridge is its single writer).
///
/// One instance per app rather than per project: the switch is machine-wide, and
/// every capture host on the machine has to see the same revocation at the same
/// moment. That is also why this is a plain object behind a [Provider] instead
/// of an `AsyncNotifier` — [ScreenShareService] needs [enabled] synchronously
/// and [changes] as a stream, neither of which an `AsyncValue` gives it.
class HostScreenControlPolicy implements ScreenControlPolicy {
  HostScreenControlPolicy({
    required Future<HostControlClient> Function() client,
  }) : _client = client;

  final Future<HostControlClient> Function() _client;
  final _changes = StreamController<bool>.broadcast();

  /// Off until the bridge says otherwise. A capture host that starts before the
  /// first read lands must refuse rather than share on an assumption.
  bool _enabled = false;

  @override
  bool get enabled => _enabled;

  @override
  Stream<bool> get changes => _changes.stream;

  Future<bool> refresh() async =>
      _apply((await (await _client()).screenControlGet()).enabled);

  Future<bool> setEnabled(bool next) async =>
      _apply((await (await _client()).screenControlSet(next)).enabled);

  /// Adopt what the bridge reported. Only ever called on a SUCCESSFUL round
  /// trip: a read that threw is a loopback blip, not evidence of revocation, and
  /// flipping the cache off on one would tear down a live session the user never
  /// ended. Nothing is lost by holding the last-known value — the bridge's own
  /// store is the authority the outbound gate consults.
  bool _apply(bool next) {
    final changed = next != _enabled;
    _enabled = next;
    // Every `false` is announced, not just a change. The capability lives in a
    // peer connection nothing here can see, so a redundant off must still reach
    // whoever holds one — the same discipline the bridge store applies to its
    // own revocation hooks.
    if (changed || !next) _changes.add(next);
    return next;
  }

  void dispose() => _changes.close();
}

/// The one policy instance, warmed on first read.
final hostScreenControlPolicyProvider = Provider<HostScreenControlPolicy>((
  ref,
) {
  final policy = HostScreenControlPolicy(
    client: () => ref.read(hostControlClientProvider.future),
  );
  ref.onDispose(policy.dispose);
  // Kick the first read here rather than leaving it to whoever asks first: the
  // panel may never be opened, and a capture host that reads `enabled` before
  // anything has loaded it would report the machine as off. A failure leaves the
  // fail-closed default in place, which is the honest answer for a host we can't
  // reach.
  unawaited(policy.refresh().catchError((_) => policy.enabled));
  return policy;
});

/// The switch as the UI sees it — the same object, wrapped so the panel gets the
/// loading/error states it renders from.
final screenControlSwitchProvider =
    AsyncNotifierProvider<ScreenControlSwitchNotifier, bool>(
      ScreenControlSwitchNotifier.new,
    );

class ScreenControlSwitchNotifier extends AsyncNotifier<bool> {
  HostScreenControlPolicy get _policy =>
      ref.read(hostScreenControlPolicyProvider);

  @override
  Future<bool> build() => _policy.refresh();

  /// Flip the machine-wide switch. The bridge's response is the resulting state,
  /// so the notifier never has to guess what landed.
  Future<void> setEnabled(bool enabled) async {
    // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
    state = const AsyncLoading<bool>().copyWithPrevious(state);
    try {
      state = AsyncData(await _policy.setEnabled(enabled));
    } catch (e, st) {
      // Retain the last-known value under the error: the panel surfaces the
      // failure separately, and a switch that vanishes mid-flip tells the user
      // less than one that still shows where the machine stands.
      // ignore: invalid_use_of_internal_member — retain prior AsyncValue during imperative mutation; v3 auto-retention only covers build() reloads, not manual state sets. Rewrite deferred (final-review triage).
      state = AsyncError<bool>(e, st).copyWithPrevious(state);
    }
  }
}
