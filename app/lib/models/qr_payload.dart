import 'dart:convert';
import 'dart:typed_data';

class QrPayload {
  final String relayUrl;
  final String agentDeviceId;
  final Uint8List agentEd25519PublicKey;
  final String pairCode;
  final String agentName;
  final String? hostMachineName;

  const QrPayload({
    required this.relayUrl,
    required this.agentDeviceId,
    required this.agentEd25519PublicKey,
    required this.pairCode,
    required this.agentName,
    this.hostMachineName,
  });

  /// Parse a v=1 `antgrid://pair?v=1&r=<relay>&d=<deviceId>&e=<ed25519>&p=<pairCode>&n=<name>` URI.
  /// Only v=1 is accepted; other versions return null.
  ///
  /// If [defaultRelayUrl] is non-null, the `r=` parameter is optional and
  /// the fallback is used instead. Empty/blank fallbacks are ignored.
  static QrPayload? parse(String raw, {String? defaultRelayUrl}) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'antgrid' || uri.host != 'pair') return null;

      final v = uri.queryParameters['v'];
      if (v != '1') return null;

      final rParam = uri.queryParameters['r'];
      final dParam = uri.queryParameters['d'];
      final eParam = uri.queryParameters['e'];
      final pParam = uri.queryParameters['p'];
      final nParam = uri.queryParameters['n'];

      final fallback = defaultRelayUrl?.trim();
      final hasFallback = fallback != null && fallback.isNotEmpty;

      if ((rParam == null && !hasFallback) ||
          dParam == null ||
          eParam == null ||
          pParam == null ||
          nParam == null) {
        return null;
      }

      if (dParam.isEmpty || pParam.isEmpty) return null;

      final relayUrl = rParam != null
          ? utf8.decode(base64Url.decode(_pad(rParam)))
          : fallback!;
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
        pairCode: pParam,
        agentName: agentName,
        hostMachineName: hostMachineName,
      );
    } catch (_) {
      return null;
    }
  }

  /// Pad base64url strings to a multiple of 4 characters.
  static String _pad(String s) {
    final remainder = s.length % 4;
    if (remainder == 0) return s;
    return s + '=' * (4 - remainder);
  }
}
