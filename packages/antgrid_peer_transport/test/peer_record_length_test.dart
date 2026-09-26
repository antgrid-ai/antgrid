import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  group('peerRecordLengthOk', () {
    test('a zero-length record is rejected', () {
      expect(peerRecordLengthOk(0, kPeerMaxBridgeRecordBytes), isFalse);
    });

    test('a length exactly at the cap is accepted', () {
      const cap = kPeerMaxBridgeRecordBytes;
      expect(peerRecordLengthOk(cap, cap), isTrue);
    });

    test('a length one past the cap is rejected', () {
      expect(
        peerRecordLengthOk(kMaxTransferBytes + 1, kPeerMaxBridgeRecordBytes),
        isFalse,
      );
    });
  });
}
