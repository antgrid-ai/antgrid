// The flow-control constants are hand-mirrored from
// `packages/antgrid-wire/src/flow.ts`, so nothing but these relationships
// catches a mirror that drifted into an unworkable shape. Each one is a rule
// the sender and receiver both depend on, not a restatement of a literal.
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  test('a receiver credits at least twice per window', () {
    // At window/2 or coarser the sender would spend most of a window blocked
    // waiting for the credit that releases it.
    expect(kCreditBatchBytes * 2, lessThanOrEqualTo(kChannelWindowBytes));
  });

  test('one maximal frame fits in an empty window', () {
    expect(
      kChannelWindowBytes,
      greaterThanOrEqualTo(kMaxFramePayload + kSealOverheadBytes),
    );
  });

  test('the socket cap leaves headroom above a full channel window', () {
    // Equal limits would let one saturated channel block the other, which is
    // the head-of-line the per-channel window exists to prevent.
    expect(kSocketInflightBytes, greaterThan(kChannelWindowBytes));
  });

  test('the send queue can hold a maximal transfer', () {
    // A message the fragmenter accepts must never be refused by the queue: it
    // would be dropped whole after the caller was told nothing.
    expect(kMaxSendQueueBytes, greaterThanOrEqualTo(kMaxTransferBytes));
  });

  test('the seal overhead matches what the transport actually adds', () async {
    // The sender checks its window BEFORE sealing, so this number is the whole
    // basis of the check. Measured, not asserted against a literal.
    final t = E2eTransportDart(
      sendKey: Uint8List(32)..fillRange(0, 32, 7),
      recvKey: Uint8List(32)..fillRange(0, 32, 9),
    );
    const plaintext = 'flow-control overhead probe';
    final sealed = await t.seal(plaintext);
    expect(sealed.length - utf8ByteLength(plaintext), kSealOverheadBytes);
  });
}
