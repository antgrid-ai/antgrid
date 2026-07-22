// Mirror of the sealed-payload stream envelope in antgrid-wire
// (relay-protocol.ts §"Sealed stream envelope"). Endpoint-internal — the relay
// never sees this (it lives inside the ciphertext); one machine socket
// multiplexes project streams by `s`.

/// Machine control-plane stream id. `s` absent or "0" = machine control plane.
const String kControlStreamId = '0';

/// Sealed-payload stream envelope `{ s?, m }`. `m` is an opaque agent message
/// (AbMessage on the bridge side); this package only shares the field names.
class StreamEnvelope {
  final String? s;
  final Object? m;

  const StreamEnvelope({this.s, required this.m});

  Map<String, dynamic> toJson() => {
    if (s != null) 's': s,
    'm': m,
  };

  static StreamEnvelope? fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('m')) return null;
    final s = json['s'];
    if (s != null && s is! String) return null;
    return StreamEnvelope(s: s as String?, m: json['m']);
  }
}
