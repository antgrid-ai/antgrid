// Coverage for `TerminalAttachment` on both paths: the socket-path
// `SocketTerminalAttachments` used by every `BufferedAgentTransport`, and the
// native-stream `_StreamTerminalAttachment` every `StreamTransport` opens.
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/native_stream_link.dart';

void main() {
  group('SocketTerminalAttachments (socket path)', () {
    test(
      'sends subscribe through send and diverts subscribed, frames, statuses '
      'and pages for its attachment only',
      () async {
        final sent = <Map<String, dynamic>>[];
        final atts = SocketTerminalAttachments((m) async => sent.add(m));

        final a = atts.open(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final b = atts.open(
          requestId: 'r2',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r2'},
        );
        expect(sent, [
          {'type': 'terminal:subscribe', 'requestId': 'r1'},
          {'type': 'terminal:subscribe', 'requestId': 'r2'},
        ]);

        final aMsgs = <Map<String, dynamic>>[];
        final bMsgs = <Map<String, dynamic>>[];
        a.messages.listen(aMsgs.add);
        b.messages.listen(bMsgs.add);

        expect(
          atts.divert({
            'type': 'terminal:subscribed',
            'requestId': 'r1',
            'attachmentId': 'att-1',
          }),
          isTrue,
        );
        expect(
          atts.divert({
            'type': 'terminal:frame',
            'attachmentId': 'att-1',
            'seq': 1,
          }),
          isTrue,
        );
        expect(
          atts.divert({
            'type': 'terminal:history:page',
            'attachmentId': 'att-1',
            'page': 0,
          }),
          isTrue,
        );
        // b's attachmentId never arrived, so a frame naming another
        // attachment reaches neither handle.
        expect(
          atts.divert({'type': 'terminal:frame', 'attachmentId': 'att-2'}),
          isFalse,
        );

        await pump();
        expect(aMsgs, hasLength(3));
        expect(bMsgs, isEmpty);
      },
    );

    test(
      'a requestId-addressed status reaches the attachment before subscribed',
      () async {
        final atts = SocketTerminalAttachments((_) async {});
        final a = atts.open(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final msgs = <Map<String, dynamic>>[];
        a.messages.listen(msgs.add);

        expect(
          atts.divert({
            'type': 'terminal:display:status',
            'requestId': 'r1',
            'status': 'UPGRADE_REQUIRED',
          }),
          isTrue,
        );

        await pump();
        expect(msgs, hasLength(1));
        expect(msgs.single['status'], 'UPGRADE_REQUIRED');
      },
    );

    test('after close() a late reply is not diverted', () async {
      final atts = SocketTerminalAttachments((_) async {});
      final a = atts.open(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      expect(
        atts.divert({
          'type': 'terminal:subscribed',
          'requestId': 'r1',
          'attachmentId': 'att-1',
        }),
        isTrue,
      );
      await a.close();
      expect(await a.done, isA<TerminalAttachmentClosedLocally>());

      // A late frame for the now-forgotten attachmentId reaches nobody.
      expect(
        atts.divert({'type': 'terminal:frame', 'attachmentId': 'att-1'}),
        isFalse,
      );
    });

    test('closeAll ends every open attachment TransportClosed', () async {
      final atts = SocketTerminalAttachments((_) async {});
      final a = atts.open(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final b = atts.open(
        requestId: 'r2',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r2'},
      );
      atts.closeAll();
      expect(await a.done, isA<TerminalAttachmentTransportClosed>());
      expect(await b.done, isA<TerminalAttachmentTransportClosed>());
    });

  });

  group('_StreamTerminalAttachment (native-stream path)', () {
    late NativeStreamLink link;

    setUp(() {
      link = NativeStreamLink();
    });

    tearDown(() async {
      await link.session.dispose();
    });

    test('records arrive on messages in record order', () async {
      final transport = await link.bind('proj-a', clearTracking: false);
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.last;
      fakeStream.emit({
        'type': 'terminal:subscribed',
        'requestId': 'r1',
        'attachmentId': 'att-1',
      });
      fakeStream.emit({
        'type': 'terminal:frame',
        'attachmentId': 'att-1',
        'seq': 1,
      });
      fakeStream.emit({
        'type': 'terminal:frame',
        'attachmentId': 'att-1',
        'seq': 2,
      });

      final received = await attachment.messages.take(3).toList();
      expect(received[0]['type'], 'terminal:subscribed');
      expect(received[1]['seq'], 1);
      expect(received[2]['seq'], 2);
    });

    test(
      'bridge FIN ends PeerEnded, finishes the send half and releases the '
      'slot',
      () async {
        final transport = await link.bind('proj-a', clearTracking: false);
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.last;
        fakeStream.emit({'type': 'terminal:subscribed', 'requestId': 'r1'});
        await pump();
        await fakeStream.endPeer();

        final end = await attachment.done;
        expect(end, isA<TerminalAttachmentPeerEnded>());
        expect(fakeStream.finishCalled, isTrue);

        // The slot the ended attachment held must be reclaimed: a fresh
        // batch of kStreamMaxTerminalAttachmentsPerPeer opens must all
        // succeed in taking a slot (none locally fail CAP_EXCEEDED).
        final fresh = <TerminalAttachment>[];
        for (var i = 0; i < kStreamMaxTerminalAttachmentsPerPeer; i++) {
          fresh.add(
            transport.openTerminalAttachment(
              requestId: 'fresh-$i',
              checkoutId: 'main',
              subscribe: {'type': 'terminal:subscribe', 'requestId': 'fresh-$i'},
            ),
          );
        }
        // link.opens[0] is the project's own bind stream opened by `bind()`.
        expect(link.opens, hasLength(2 + kStreamMaxTerminalAttachmentsPerPeer));
      },
    );

    test('close() finishes the send half and ends ClosedLocally', () async {
      final transport = await link.bind('proj-a', clearTracking: false);
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.last;
      fakeStream.emit({'type': 'terminal:subscribed', 'requestId': 'r1'});
      await pump();

      final delivered = <Map<String, dynamic>>[];
      attachment.messages.listen(delivered.add);
      await pump();

      await attachment.close();
      expect(await attachment.done, isA<TerminalAttachmentClosedLocally>());
      expect(fakeStream.finishCalled, isTrue);

      // Draining continues after close, but nothing more is delivered.
      fakeStream.emit({'type': 'terminal:frame', 'attachmentId': 'att-1'});
      await fakeStream.endPeer();
      await pump();
      expect(delivered, hasLength(1));
      expect(delivered.single['type'], 'terminal:subscribed');
    });

  });
}
