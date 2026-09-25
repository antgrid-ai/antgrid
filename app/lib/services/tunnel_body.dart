import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Decode one tunneled body record as the bridge encoded it. [r.gzip] means
/// [r.bytes] is one independent gzip member (mirrors `encodeTunnelDataRecord`
/// tagging in `bridge/src/localhost-fetch.ts`), so no decoder state crosses
/// records — a record can be decoded the moment it arrives.
///
/// Throws [FormatException] for a gzip member that fails to decode — the
/// caller turns that into a [TunnelStreamException], so a corrupt or
/// truncated member is a logged failure rather than a body that silently
/// stops.
Uint8List decodeTunnelBody(TunnelBodyRecord r) {
  if (!r.gzip) return r.bytes;
  try {
    return Uint8List.fromList(gzip.decode(r.bytes));
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('undecodable gzip tunnel body: $e');
  }
}
