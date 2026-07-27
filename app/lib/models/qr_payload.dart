import 'dart:convert';
import 'dart:typed_data';

class QrPayload {
  final String relayUrl;
  final String agentDeviceId;
  final Uint8List agentEd25519PublicKey;
  final String agentName;
  final String? hostMachineName;

  const QrPayload({
    required this.relayUrl,
    required this.agentDeviceId,
    required this.agentEd25519PublicKey,
    required this.agentName,
    this.hostMachineName,
  });

  /// Parse a v=1 `antgrid://pair?v=1&r=<relay>&d=<deviceId>&e=<ed25519>&n=<name>` URI.
  /// Only v=1 is accepted; other versions return null.
  ///
  /// `p=` (the single-use pair code) is no longer emitted by the bridge
  /// (`bridge/src/connect-uri.ts`) — admission is account trust, so nothing on
  /// this side consumes it any more. It is still accepted and ignored if present,
  /// because an already-printed or screenshotted QR from before that change
  /// may still carry it, and a payload carrying it must keep parsing.
  ///
  /// If [defaultRelayUrl] is non-null, the `r=` parameter is optional and
  /// the fallback is used instead. Empty/blank fallbacks are ignored. An `r=`
  /// that does not decode to a ws/wss/http(s) URL counts as absent, so it takes
  /// the fallback too (and fails the parse outright when there is none).
  static QrPayload? parse(String raw, {String? defaultRelayUrl}) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'antgrid' || uri.host != 'pair') return null;

      final v = uri.queryParameters['v'];
      if (v != '1') return null;

      final rParam = uri.queryParameters['r'];
      final dParam = uri.queryParameters['d'];
      final eParam = uri.queryParameters['e'];
      final nParam = uri.queryParameters['n'];

      final fallback = defaultRelayUrl?.trim();
      final hasFallback = fallback != null && fallback.isNotEmpty;

      if ((rParam == null && !hasFallback) ||
          dParam == null ||
          eParam == null ||
          nParam == null) {
        return null;
      }

      if (dParam.isEmpty) return null;

      // A present-but-unparseable `r=` is treated as absent rather than adopted
      // verbatim: a relay coordinate that is not a URL can only fail later, at
      // dial time, with no way back to the default.
      final decodedRelay = rParam != null
          ? utf8.decode(base64Url.decode(_pad(rParam)))
          : null;
      final relayUrl = _isRelayUrl(decodedRelay)
          ? decodedRelay!
          : (hasFallback ? fallback : null);
      if (relayUrl == null) return null;
      final agentName = utf8.decode(base64Url.decode(_pad(nParam)));
      final hParam = uri.queryParameters['h'];
      final hostMachineName = hParam != null
          ? utf8.decode(base64Url.decode(_pad(hParam)))
          : null;
      final ed25519 = Uint8List.fromList(base64Url.decode(_pad(eParam)));

      if (ed25519.length != 32) return null;

      return QrPayload(
        relayUrl: relayUrl,
        agentDeviceId: dParam,
        agentEd25519PublicKey: ed25519,
        agentName: agentName,
        hostMachineName: hostMachineName,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _isRelayUrl(String? value) {
    if (value == null) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return false;
    return const {'ws', 'wss', 'http', 'https'}.contains(uri.scheme);
  }

  /// Pad base64url strings to a multiple of 4 characters.
  static String _pad(String s) {
    final remainder = s.length % 4;
    if (remainder == 0) return s;
    return s + '=' * (4 - remainder);
  }
}
