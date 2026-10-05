import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:test/test.dart';

void main() {
  final dialed = 'aa' * 32;
  final other = 'bb' * 32;

  test('an endpoint other than the one dialed is a terminal mismatch', () {
    final failure = classifyDialedConnection(
      expectedEndpointId: dialed,
      remoteEndpointId: other,
      alpn: peerAlpn,
      authorized: true,
    );
    expect(failure?.code, 'AUTHENTICATED_ENDPOINT_MISMATCH');
    expect(failure?.terminal, isTrue);
  });

  test('a foreign ALPN is a terminal mismatch', () {
    final failure = classifyDialedConnection(
      expectedEndpointId: dialed,
      remoteEndpointId: dialed,
      alpn: 'antgrid/peer/1',
      authorized: true,
    );
    expect(failure?.code, 'AUTHENTICATED_ENDPOINT_MISMATCH');
    expect(failure?.terminal, isTrue);
  });

  test('a mismatch outranks a lapsed lease', () {
    final failure = classifyDialedConnection(
      expectedEndpointId: dialed,
      remoteEndpointId: other,
      alpn: peerAlpn,
      authorized: false,
    );
    expect(failure?.code, 'AUTHENTICATED_ENDPOINT_MISMATCH');
    expect(failure?.terminal, isTrue);
  });

  test('a lease that lapsed during the dial is retryable', () {
    final failure = classifyDialedConnection(
      expectedEndpointId: dialed,
      remoteEndpointId: dialed,
      alpn: peerAlpn,
      authorized: false,
    );
    expect(failure, same(authorizationChangedDuringConnect));
    expect(failure?.code, 'AUTHORIZATION_CHANGED_DURING_CONNECT');
    expect(failure?.terminal, isFalse);
    expect(failure?.retryable, isTrue);
    expect(failure?.cancelled, isFalse);
  });

  test('an authenticated, still-authorized connection passes', () {
    expect(
      classifyDialedConnection(
        expectedEndpointId: dialed,
        remoteEndpointId: dialed,
        alpn: peerAlpn,
        authorized: true,
      ),
      isNull,
    );
  });
}
