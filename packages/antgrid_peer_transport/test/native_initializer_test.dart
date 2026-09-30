import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:test/test.dart';

class _UnopenedKeys implements EndpointKeyStore {
  @override
  Future<Uint8List?> read(String enrollmentId) async =>
      throw StateError('key read before native initialization completed');
  @override
  Future<void> write(String enrollmentId, Uint8List secret) async =>
      throw StateError('unexpected key write');
  @override
  Future<void> delete(String enrollmentId) async =>
      throw StateError('unexpected key delete');
}

void main() {
  test(
    'injected initialization failure cannot fall through to default loader',
    () async {
      final failure = StateError('bundled library unavailable');
      var initializations = 0;
      await expectLater(
        NativeEndpointOwner.create(
          enrollmentId: 'enrollment',
          keyStore: _UnopenedKeys(),
          approvedRelays: const [],
          initializeNative: () async {
            initializations++;
            throw failure;
          },
        ),
        throwsA(same(failure)),
      );
      expect(initializations, 1);
    },
  );
}
