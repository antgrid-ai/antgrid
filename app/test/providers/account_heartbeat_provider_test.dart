import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_heartbeat.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/keychain_device_store.dart';

/// Counts heartbeat attempts. `readIfMatchesUser` is the first await inside
/// `beat()` and returning null aborts it there, so the count is an exact "a
/// beat ran" tally. The minter/apiUrl overrides in the harness are backstops
/// only — they keep a reordering of `beat()` from reaching the network rather
/// than being reached today.
class _CountingStore extends KeychainDeviceStore {
  _CountingStore() : super(storage: _NullStorage());

  int beats = 0;

  @override
  Future<DeviceRecord?> readIfMatchesUser(String userId) async {
    beats++;
    return null;
  }
}

class _NullStorage implements DeviceSecretStorage {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String s) async {}
  @override
  Future<void> delete() async {}
}

const _interval = Duration(minutes: 5);

/// Let riverpod deliver the pending `currentUserProvider` state (an async
/// provider settles over more than microtasks) without reaching the first
/// periodic tick.
void _settle(FakeAsync async) => async.elapse(const Duration(seconds: 1));

void main() {
  // Activated with `container.listen`, never a bare `read`: in riverpod 3 a
  // read closes its subscription immediately, which deactivates the provider's
  // own `ref.listen(currentUserProvider, ...)` before any sign-in lands. Same
  // reason main.dart uses listen — see the call site there.
  ({ProviderContainer container, _CountingStore store}) harness(
    CurrentUser? Function() user,
  ) {
    final store = _CountingStore();
    final container = ProviderContainer(
      overrides: [
        keychainDeviceStoreProvider.overrideWithValue(store),
        licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
        licenseTokenMinterProvider.overrideWith((ref) async => null),
        currentUserProvider.overrideWith((ref) => user()),
      ],
    );
    return (container: container, store: store);
  }

  test('does not beat while signed out', () {
    fakeAsync((async) {
      final h = harness(() => null);
      h.container.listen(accountHeartbeatProvider, (_, _) {});
      async.elapse(_interval * 3);
      expect(h.store.beats, 0);
      h.container.dispose();
    });
  });

  test('beats immediately on sign-in, then once per interval', () {
    fakeAsync((async) {
      CurrentUser? user;
      final h = harness(() => user);
      h.container.listen(accountHeartbeatProvider, (_, _) {});

      user = CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro');
      h.container.invalidate(currentUserProvider);
      _settle(async);
      expect(h.store.beats, 1, reason: 'the sign-in beat is immediate');

      async.elapse(_interval * 2);
      expect(h.store.beats, 3);
      h.container.dispose();
    });
  });

  test('sign-out cancels the timer', () {
    fakeAsync((async) {
      CurrentUser? user = CurrentUser(
        userId: 'u-1',
        email: 'a@b.test',
        tier: 'pro',
      );
      final h = harness(() => user);
      h.container.listen(accountHeartbeatProvider, (_, _) {});
      async.elapse(_interval);
      final beforeSignOut = h.store.beats;
      expect(beforeSignOut, greaterThan(0));

      user = null;
      h.container.invalidate(currentUserProvider);
      async.elapse(_interval * 3);

      expect(h.store.beats, beforeSignOut);
      h.container.dispose();
    });
  });

  test('a re-sign-in leaves exactly one timer running, not two', () {
    // The listener cancels before re-arming; without that cancel every
    // sign-out/sign-in cycle would double the beat rate for the app's lifetime.
    fakeAsync((async) {
      CurrentUser? user = CurrentUser(
        userId: 'u-1',
        email: 'a@b.test',
        tier: 'pro',
      );
      final h = harness(() => user);
      h.container.listen(accountHeartbeatProvider, (_, _) {});
      _settle(async);

      user = null;
      h.container.invalidate(currentUserProvider);
      _settle(async);
      user = CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro');
      h.container.invalidate(currentUserProvider);
      _settle(async);

      final afterSignIn = h.store.beats;
      async.elapse(_interval);
      expect(h.store.beats, afterSignIn + 1);
      h.container.dispose();
    });
  });

  test('disposing the container cancels the timer', () {
    fakeAsync((async) {
      final h = harness(
        () => CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro'),
      );
      h.container.listen(accountHeartbeatProvider, (_, _) {});
      _settle(async);
      h.container.dispose();

      final afterDispose = h.store.beats;
      async.elapse(_interval * 3);
      expect(h.store.beats, afterDispose);
      // A surviving Timer.periodic would also trip fake_async's pending-timer
      // check on the enclosing zone teardown.
    });
  });
}
