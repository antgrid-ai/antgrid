import 'dart:async';

import 'package:antgrid/connection/peer_runtime_owner.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Runtime {
  _Runtime(this.name);
  final String name;
}

PeerRuntimeIdentity _identity(
  String enrollment, {
  String account = 'account-a',
  String secret = 'endpoint-secret-a',
}) => PeerRuntimeIdentity(
  accountId: account,
  enrollmentId: enrollment,
  endpointSecret: secret,
);

void main() {
  test('identity includes account, enrollment, and endpoint secret', () {
    final base = _identity('enrollment-a');
    expect(base, _identity('enrollment-a'));
    expect(base, isNot(_identity('enrollment-b')));
    expect(base, isNot(_identity('enrollment-a', account: 'account-b')));
    expect(base, isNot(_identity('enrollment-a', secret: 'endpoint-secret-b')));
    expect(base.toString(), isNot(contains('endpoint-secret-a')));
    expect(base.endpointSecretIdentity, isNot('endpoint-secret-a'));
  });

  test('concurrent obtains of the same identity reuse one runtime', () async {
    var creates = 0;
    final creation = Completer<_Runtime>();
    final owner = PeerRuntimeOwner<_Runtime, String>(
      create: (value) {
        creates++;
        return creation.future;
      },
      dispose: (_) async => const PeerRuntimeCleanupResult.complete(),
    );
    final identity = _identity('enrollment-a');

    final first = owner.obtain(identity, 'first');
    final second = owner.obtain(identity, 'second');
    creation.complete(_Runtime('shared'));

    final values = await Future.wait([first, second]);
    expect(creates, 1);
    expect(values[1], same(values[0]));
    expect(owner.runtime, same(values[0]));
  });

  test('replacement waits for confirmed previous disposal', () async {
    final events = <String>[];
    final disposalStarted = Completer<void>();
    final allowDisposal = Completer<void>();
    final owner = PeerRuntimeOwner<_Runtime, String>(
      create: (value) {
        events.add('create:$value');
        return _Runtime(value);
      },
      dispose: (runtime) async {
        events.add('dispose-start:${runtime.name}');
        disposalStarted.complete();
        await allowDisposal.future;
        events.add('dispose-end:${runtime.name}');
        return const PeerRuntimeCleanupResult.complete();
      },
    );
    await owner.obtain(_identity('enrollment-a'), 'a');

    final replacement = owner.obtain(_identity('enrollment-b'), 'b');
    await disposalStarted.future;
    expect(events, ['create:a', 'dispose-start:a']);
    allowDisposal.complete();

    final next = await replacement;
    expect(next.name, 'b');
    expect(events, [
      'create:a',
      'dispose-start:a',
      'dispose-end:a',
      'create:b',
    ]);
  });

  test('incomplete cleanup locks creation until clear confirms it', () async {
    var disposals = 0;
    final created = <String>[];
    final owner = PeerRuntimeOwner<_Runtime, String>(
      create: (value) {
        created.add(value);
        return _Runtime(value);
      },
      dispose: (_) async {
        disposals++;
        if (disposals == 1) {
          return const PeerRuntimeCleanupResult.incomplete('still-owned');
        }
        return const PeerRuntimeCleanupResult.complete();
      },
    );
    final first = await owner.obtain(_identity('enrollment-a'), 'a');

    await expectLater(
      owner.obtain(_identity('enrollment-b'), 'b'),
      throwsA(isA<PeerRuntimeOwnerLockedException>()),
    );
    expect(owner.isLocked, isTrue);
    expect(owner.runtime, same(first));
    expect(owner.cleanupFailure?.reason, 'still-owned');
    expect(created, ['a']);

    await expectLater(
      owner.obtain(_identity('enrollment-c'), 'c'),
      throwsA(isA<PeerRuntimeOwnerLockedException>()),
    );
    expect(disposals, 1);
    expect((await owner.clear()).complete, isTrue);
    expect(owner.isLocked, isFalse);

    final recovered = await owner.obtain(_identity('enrollment-c'), 'c');
    expect(recovered.name, 'c');
    expect(created, ['a', 'c']);
  });

  test('a throwing disposer also locks the owner', () async {
    final owner = PeerRuntimeOwner<_Runtime, String>(
      create: _Runtime.new,
      dispose: (_) async => throw StateError('close failed'),
    );
    await owner.obtain(_identity('enrollment-a'), 'a');

    await expectLater(
      owner.replace(_identity('enrollment-a'), 'replacement'),
      throwsA(isA<PeerRuntimeOwnerLockedException>()),
    );
    expect(owner.isLocked, isTrue);
    expect(owner.cleanupFailure?.reason, isA<StateError>());
    expect(owner.runtime?.name, 'a');
  });

  test('explicit replace recreates even the same identity', () async {
    var creates = 0;
    var disposals = 0;
    final owner = PeerRuntimeOwner<_Runtime, String>(
      create: (value) => _Runtime('$value-${++creates}'),
      dispose: (_) async {
        disposals++;
        return const PeerRuntimeCleanupResult.complete();
      },
    );
    final identity = _identity('enrollment-a');
    final first = await owner.obtain(identity, 'runtime');
    final second = await owner.replace(identity, 'runtime');

    expect(second, isNot(same(first)));
    expect(creates, 2);
    expect(disposals, 1);
  });
}
