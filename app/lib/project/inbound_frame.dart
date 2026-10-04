import '../models/ab_message.dart';
import '../util/ab_log.dart';
import 'project_message_classification.dart';

/// Turns a raw envelope into its typed message, or null for an unknown type.
/// May throw on a malformed payload.
typedef FrameParser = Object? Function(Map<String, dynamic> json);

/// One inbound control-channel envelope, shared by every consumer of the
/// router's tiers and by durable replay.
///
/// Parsing is lazy and memoised so a frame costs at most one parse no matter
/// how many services see it, and none when nobody reads [parsed]. The parsed
/// object is shared between those consumers: treat it, and any list or map it
/// holds, as read-only.
final class InboundFrame {
  InboundFrame(this.json, {FrameParser parser = parseAbMessage})
    : _parser = parser;

  /// The raw envelope, never copied.
  final Map<String, dynamic> json;
  final FrameParser _parser;

  String? get type {
    final t = json['type'];
    return t is String ? t : null;
  }

  late final String checkoutId = checkoutIdForEnvelope(json);

  /// Null for an unknown type and for a malformed payload alike.
  ///
  /// The catch lives inside the initializer on purpose: a `late final` whose
  /// initializer throws stays unset and would re-run the parser for every
  /// reader.
  late final Object? parsed = _parseSafely();

  Object? _parseSafely() {
    try {
      return _parser(json);
    } catch (e, st) {
      AbLog.error(
        'InboundFrame',
        'malformed inbound frame',
        fields: {'type': type, 'error': '$e', 'stack': '$st'},
      );
      return null;
    }
  }

  @override
  String toString() => 'InboundFrame($type)';
}
