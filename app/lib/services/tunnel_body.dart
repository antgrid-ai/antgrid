import 'dart:convert';
import 'dart:io';

import '../models/preview_models.dart';

/// Decode one tunneled body slice as the bridge encoded it (`encodeChunk` in
/// `bridge/src/localhost-fetch.ts`).
///
/// Every gzip slice is an INDEPENDENT member, so no decoder state crosses
/// slices: a slice can be decoded the moment it arrives, and the encoding is
/// free to differ from one slice to the next.
///
/// Throws [FormatException] for anything it cannot decode — the caller turns
/// that into a [TunnelStreamException] naming the value, so an encoding the
/// bridge added and the app does not know is a logged failure rather than a
/// body that silently stops.
List<int> decodeTunnelSlice(String data, String bodyEncoding) {
  final raw = base64Decode(data);
  if (bodyEncoding == 'base64') return raw;
  if (bodyEncoding == kTunnelGzipEncoding) return gzip.decode(raw);
  throw FormatException('unknown tunnel bodyEncoding "$bodyEncoding"');
}
