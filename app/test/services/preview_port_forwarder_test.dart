import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/services/preview_port_forwarder.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/free_port.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late List<FakeTunnelTcpChannel> channels;
  late PreviewPortForwarder forwarder;
  late int port;

  Future<void> startOn(int preferred) async {
    forwarder = PreviewPortForwarder(
      open: (connId) {
        final channel = FakeTunnelTcpChannel(
          connId: connId,
          port: 3000,
          checkoutId: 'main',
          probe: false,
        );
        channels.add(channel);
        return channel;
      },
    );
    port = await forwarder.start(preferred);
    addTearDown(forwarder.close);
  }

  setUp(() => channels = []);

  Future<(Socket, StreamController<List<int>>)> connect() async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(socket.destroy);
    final received = StreamController<List<int>>();
    socket.listen(received.add, onDone: received.close, onError: (_) {});
    return (socket, received);
  }

  test('binds the requested port and opens one channel per connection', () async {
    final preferred = await freePort();
    await startOn(preferred);
    expect(port, preferred);

    await connect();
    await connect();
    await _waitUntil(() => channels.length == 2);
    expect(channels[0].connId, isNot(channels[1].connId));
  });

  test('bytes flow both ways once the bridge is ready', () async {
    await startOn(await freePort());
    final (socket, received) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single..completeReady();

    socket.add(_b('GET / HTTP/1.1\r\n\r\n'));
    await socket.flush();
    await _waitUntil(() => channel.sent.isNotEmpty);
    expect(String.fromCharCodes(channel.sent.first), startsWith('GET /'));

    channel.addIncoming(_b('HTTP/1.1 200 OK\r\n\r\n'));
    final first = await received.stream.first;
    expect(String.fromCharCodes(first), startsWith('HTTP/1.1 200'));
  });

  test('nothing is sent before ready', () async {
    await startOn(await freePort());
    final (socket, _) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single;

    socket.add(_b('early'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(channel.sent, isEmpty);

    channel.completeReady();
    await _waitUntil(() => channel.sent.isNotEmpty);
    expect(String.fromCharCodes(channel.sent.first), 'early');
  });

  test('a failed ready destroys the local socket and aborts the channel',
      () async {
    await startOn(await freePort());
    final (_, received) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single;

    channel.failReady(const TunnelExchangeFailure('UNREACHABLE'));

    await received.stream.drain<void>().timeout(const Duration(seconds: 3));
    expect(channel.aborted, isTrue);
  });

  test('the bridge FIN closes the local socket after queued bytes', () async {
    await startOn(await freePort());
    final (_, received) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single..completeReady();

    channel.addIncoming(_b('tail'));
    channel.endFromBridge();

    final all = <int>[];
    await received.stream
        .forEach(all.addAll)
        .timeout(const Duration(seconds: 3));
    expect(String.fromCharCodes(all), 'tail');
    expect(channel.aborted, isFalse);
  });

  test('a bridge reset destroys the local socket', () async {
    await startOn(await freePort());
    final (_, received) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single..completeReady();

    channel.resetFromBridge();

    await received.stream.drain<void>().timeout(const Duration(seconds: 3));
    expect(channel.aborted, isTrue);
  });

  test('the local socket closing finishes the channel', () async {
    await startOn(await freePort());
    final (socket, _) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single..completeReady();

    await socket.close();

    await _waitUntil(() => channel.finished);
    expect(channel.aborted, isFalse);
  });

  test('each send is awaited before the socket is read again', () async {
    await startOn(await freePort());
    final (socket, _) = await connect();
    await _waitUntil(() => channels.isNotEmpty);
    final channel = channels.single..completeReady();
    final gate = Completer<void>();
    channel.sendGate = gate.future;

    socket.add(_b('one'));
    await socket.flush();
    await _waitUntil(() => channel.sent.length == 1);
    socket.add(_b('two'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(channel.sent, hasLength(1));

    gate.complete();
    await _waitUntil(() => channel.sent.length == 2);
  });

  test('close aborts every live channel and stops listening', () async {
    await startOn(await freePort());
    await connect();
    await connect();
    await _waitUntil(() => channels.length == 2);
    channels.first.completeReady();

    await forwarder.close();

    expect(channels.every((c) => c.aborted), isTrue);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );
  });

  test('falls back to an ephemeral port when the port is taken', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(blocker.close);

    await startOn(blocker.port);

    expect(port, isNot(blocker.port));
    expect(port, greaterThan(0));
    await connect();
    await _waitUntil(() => channels.length == 1);
  });

  group('IPv6 loopback', () {
    late bool hasIpv6;

    setUpAll(() async {
      try {
        final probe = await ServerSocket.bind(
          InternetAddress.loopbackIPv6,
          0,
          v6Only: true,
        );
        await probe.close();
        hasIpv6 = true;
      } on SocketException {
        hasIpv6 = false;
      }
    });

    test('moves both families to a shared port when ::1 is taken', () async {
      if (!hasIpv6) {
        markTestSkipped('no IPv6 loopback on this host');
        return;
      }
      // A foreign listener on ::1 only, the way a Node dev server bound to
      // `localhost` leaves the port free on IPv4.
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv6,
        0,
        v6Only: true,
      );
      addTearDown(blocker.close);

      await startOn(blocker.port);

      expect(port, isNot(blocker.port));
      final v4 = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(v4.destroy);
      final v6 = await Socket.connect(InternetAddress.loopbackIPv6, port);
      addTearDown(v6.destroy);
      await _waitUntil(() => channels.length == 2);
    });

    test('listens on ::1 at the requested port when both are free', () async {
      if (!hasIpv6) {
        markTestSkipped('no IPv6 loopback on this host');
        return;
      }
      final preferred = await freePort();
      await startOn(preferred);
      expect(port, preferred);

      final v6 = await Socket.connect(InternetAddress.loopbackIPv6, port);
      addTearDown(v6.destroy);
      await _waitUntil(() => channels.length == 1);
    });
  });
}
