// Coverage for the native-stream TCP tunnel (`_StreamTunnelTcpChannel` in
// `machine_session.dart`).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/native_stream_link.dart';

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('_StreamTunnelTcpChannel (native-stream path)', () {
    late NativeStreamLink link;

    setUp(() {
      link = NativeStreamLink();
    });

    tearDown(() async {
      await link.session.dispose();
    });

    TunnelTcpChannel openChannel(
      StreamTransport transport, {
      String connId = 'c1',
      int port = 3000,
      bool probe = false,
    }) => transport.openTunnelTcp(connId: connId, port: port, probe: probe);

    Future<(TunnelTcpChannel, NativeTestStream)> openReady(
      StreamTransport transport,
    ) async {
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();
      fake.emit({'type': 'tunnel:tcp-ready', 'connId': 'c1'});
      await channel.ready;
      return (channel, fake);
    }

    test('the open frame and tcp-open record carry the port and checkout',
        () async {
      final transport = await link.bind('proj-a');
      openChannel(transport, port: 5173);

      expect(link.opens, hasLength(1));
      expect(
        link.opens.single.open,
        const TunnelTcpStreamOpen(projectId: 'proj-a', connId: 'c1'),
      );
      expect(link.opens.single.maxRecordBytes, kStreamTunnelTcpRecordMaxBytes);
      expect(link.opens.single.maxQueuedBytes, kTunnelStreamMaxQueuedBytes);

      await pump();
      final json =
          jsonDecode(utf8.decode(link.createdStreams.single.sent.single)) as Map;
      expect(json, {
        'type': 'tunnel:tcp-open',
        'connId': 'c1',
        'port': 5173,
        'checkoutId': 'main',
      });
    });

    test('a probe sets probe:true and reports tls', () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport, probe: true);
      final fake = link.createdStreams.single;
      await pump();
      expect((jsonDecode(utf8.decode(fake.sent.single)) as Map)['probe'], true);

      fake.emit({'type': 'tunnel:tcp-ready', 'connId': 'c1', 'tls': true});
      expect((await channel.ready).tls, isTrue);
      await fake.endPeer();
      await pump();
      expect(await channel.incoming.isEmpty, isTrue);
    });

    test('a plain ready has no tls verdict', () async {
      final transport = await link.bind('proj-a');
      final (channel, _) = await openReady(transport);
      expect((await channel.ready).tls, isNull);
    });

    test('tcp-error fails ready UNREACHABLE with the bridge message', () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();
      fake.emit({
        'type': 'tunnel:tcp-error',
        'connId': 'c1',
        'message': 'refused',
      });
      await fake.endPeer();

      await expectLater(
        channel.ready,
        throwsA(
          isA<TunnelExchangeFailure>()
              .having((e) => e.code, 'code', 'UNREACHABLE')
              .having((e) => e.message, 'message', 'refused'),
        ),
      );
      await pump();
      expect(fake.finishCalled, isTrue);
      expect(await channel.incoming.isEmpty, isTrue);
    });

    test('a refusal fails ready REFUSED carrying the refusal', () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();
      fake.emit(
        const StreamRefused(
          code: StreamRefusedCode.capExceeded,
          message: 'too many',
        ).toJson(),
      );
      await fake.endPeer();

      await expectLater(
        channel.ready,
        throwsA(
          isA<TunnelExchangeFailure>()
              .having((e) => e.code, 'code', 'REFUSED')
              .having(
                (e) => e.refusal?.code,
                'refusal code',
                StreamRefusedCode.capExceeded,
              )
              .having((e) => e.refusal?.message, 'refusal', 'too many'),
        ),
      );
    });

    test('a reply for another connId is a protocol breach that resets',
        () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();
      fake.emit({'type': 'tunnel:tcp-ready', 'connId': 'other'});

      await expectLater(
        channel.ready,
        throwsA(
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'PROTOCOL'),
        ),
      );
      expect(fake.resetCalled, isTrue);
      await fake.endPeer();
    });

    test('the stream ending before any reply fails ready STREAM_LOST',
        () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();
      await fake.endPeer();

      await expectLater(
        channel.ready,
        throwsA(
          isA<TunnelExchangeFailure>().having(
            (e) => e.code,
            'code',
            'STREAM_LOST',
          ),
        ),
      );
    });

    test('raw bytes flow both directions after ready', () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);

      final received = <int>[];
      channel.incoming.listen(received.addAll);
      fake.emitRaw(bytesOf('GET /'));
      fake.emitRaw(bytesOf(' HTTP'));
      await pump();
      expect(utf8.decode(received), 'GET / HTTP');

      expect(await channel.send(bytesOf('200 OK')), isTrue);
      expect(fake.sentRaw.map(utf8.decode), ['200 OK']);
    });

    test('send before ready is refused and writes nothing', () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();

      expect(await channel.send(bytesOf('early')), isFalse);
      expect(fake.sentRaw, isEmpty);
      channel.abort();
      await fake.endPeer();
    });

    test('the bridge FIN completes incoming and finishes our half', () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);
      final done = channel.incoming.toList();
      fake.emitRaw(bytesOf('tail'));
      await fake.endPeer();

      expect((await done).map(utf8.decode), ['tail']);
      await pump();
      expect(fake.finishCalled, isTrue);
      expect(fake.resetCalled, isFalse);
      expect(await channel.send(bytesOf('x')), isFalse);
    });

    test('a bridge reset errors incoming and resets our half', () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);
      final result = expectLater(
        channel.incoming.toList(),
        throwsA(isA<PeerStreamReset>()),
      );
      await fake.endWithReset();
      await result;
      expect(fake.resetCalled, isTrue);
    });

    test('send awaits the stream write and returns false once it fails',
        () async {
      final gate = Completer<void>();
      final transport = await link.bind('proj-a');
      link.onOpen = (_) => NativeTestStream()..rawGate = gate;
      final (channel, fake) = await openReady(transport);

      var settled = false;
      final sending = channel.send(bytesOf('a')).then((ok) {
        settled = true;
        return ok;
      });
      await pump();
      expect(settled, isFalse, reason: 'the write is still in flight');

      fake.sendRawOutcome = PeerSendOutcome.backpressured;
      gate.complete();
      expect(await sending, isFalse);
      expect(fake.resetCalled, isTrue);
      expect(await channel.send(bytesOf('b')), isFalse);
      await fake.endPeer();
    });

    test('finish() ends our half once and later sends return false', () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);

      await channel.finish();
      await channel.finish();
      expect(fake.finishCalled, isTrue);
      expect(fake.resetCalled, isFalse);
      expect(await channel.send(bytesOf('x')), isFalse);

      // The connection still winds down on the bridge's own FIN.
      final done = channel.incoming.toList();
      await fake.endPeer();
      expect(await done, isEmpty);
    });

    test('abort() resets, is idempotent, and closes incoming quietly',
        () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);
      final done = channel.incoming.toList();

      channel.abort();
      channel.abort();
      expect(fake.resetCalled, isTrue);
      expect(await done, isEmpty);
      expect(await channel.send(bytesOf('x')), isFalse);
      await fake.endPeer();
    });

    test('abort() before ready fails ready CANCELLED without an unhandled '
        'error', () async {
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fake = link.createdStreams.single;
      await pump();

      channel.abort();
      await expectLater(
        channel.ready,
        throwsA(
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      await fake.endPeer();
    });

    test('the slot is held until the bridge half ends, then freed for a '
        'queued open', () async {
      final transport = await link.bind('proj-a');
      final channels = [
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer; i++)
          openChannel(transport, connId: 'f$i'),
      ];
      final extra = openChannel(transport, connId: 'extra');
      await pump();
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

      channels.first.abort();
      await pump();
      expect(
        link.opens,
        hasLength(kStreamMaxTunnelStreamsPerPeer),
        reason: 'aborting alone must not free the slot',
      );

      await link.createdStreams.first.endPeer();
      await pump();
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));

      extra.abort();
      for (final c in channels.skip(1)) {
        c.abort();
      }
      for (final s in link.createdStreams) {
        await s.endPeer();
      }
    });

    test('an abort while the open is in flight keeps the slot until the '
        'stream drains', () async {
      final transport = await link.bind('proj-a');
      final gate = Completer<void>();
      link.gateOpen = (open) =>
          open is TunnelTcpStreamOpen && open.connId == 'gated'
          ? gate.future
          : null;
      final fillers = [
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++)
          openChannel(transport, connId: 'f$i'),
      ];
      final gated = openChannel(transport, connId: 'gated');
      final extra = openChannel(transport, connId: 'extra');
      await pump();
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

      gated.abort();
      await pump();
      expect(
        link.opens,
        hasLength(kStreamMaxTunnelStreamsPerPeer),
        reason: 'the bridge counts the stream once the open lands',
      );

      gate.complete();
      await pump();
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

      await link.createdStreams.last.endPeer();
      await pump();
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));

      extra.abort();
      for (final c in fillers) {
        c.abort();
      }
      for (final s in link.createdStreams) {
        await s.endPeer();
      }
    });

    test('an abort racing the slot grant does not leak the slot', () async {
      // Where the abort lands relative to the grant depends on microtask
      // ordering inside the exchange, so sweep the delay rather than rely on
      // one lucky value.
      for (var delay = 0; delay < 12; delay++) {
        final racing = link = NativeStreamLink();
        final transport = await racing.bind('proj-a');
        final channels = [
          for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer; i++)
            openChannel(transport, connId: 'f$i'),
        ];
        final queued = openChannel(transport, connId: 'queued');
        await pump();

        unawaited(racing.createdStreams.first.endPeer());
        var remaining = delay;
        void step() {
          if (remaining-- > 0) {
            scheduleMicrotask(step);
          } else {
            queued.abort();
          }
        }

        step();
        await pump();

        for (final s in racing.createdStreams.skip(1)) {
          await s.endPeer();
        }
        for (final c in channels.skip(1)) {
          c.abort();
        }
        await pump();

        racing.opens.clear();
        final fresh = [
          for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer; i++)
            openChannel(transport, connId: 'n$i'),
        ];
        await pump();
        expect(
          racing.opens,
          hasLength(kStreamMaxTunnelStreamsPerPeer),
          reason: 'delay $delay leaked a slot',
        );
        for (final c in fresh) {
          c.abort();
        }
        if (delay < 11) await racing.session.dispose();
      }
    });

    test('pausing incoming stops the native reader until it resumes',
        () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);
      final received = <Uint8List>[];
      final sub = channel.incoming.listen(received.add);

      fake.emitRaw(bytesOf('one'));
      await pump();
      expect(received, hasLength(1));
      expect(fake.recordsPaused, isFalse);

      sub.pause();
      await pump();
      expect(fake.recordsPaused, isTrue);
      for (var i = 0; i < 20; i++) {
        fake.emitRaw(bytesOf('chunk$i'));
      }
      await pump();
      expect(received, hasLength(1));

      sub.resume();
      await pump();
      expect(fake.recordsPaused, isFalse);
      expect(received, hasLength(21));

      channel.abort();
      await fake.endPeer();
    });

    test('aborting a paused channel resumes the reader so the stream drains',
        () async {
      final transport = await link.bind('proj-a');
      final (channel, fake) = await openReady(transport);
      final sub = channel.incoming.listen((_) {});
      sub.pause();
      await pump();
      expect(fake.recordsPaused, isTrue);

      channel.abort();
      await pump();
      expect(fake.recordsPaused, isFalse);
      await fake.endPeer();
    });
  });
}
