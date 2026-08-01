class PortInfo {
  final int port;
  final int? pid;
  final String? processName;
  final String? label;

  /// Dev-server scheme detected by the bridge ('http'/'https'). Null when the
  /// bridge hasn't seen a URL for this port yet — treat as http.
  final String? scheme;

  const PortInfo({
    required this.port,
    this.pid,
    this.processName,
    this.label,
    this.scheme,
  });

  static PortInfo? fromJson(Map<String, dynamic> json) {
    final port = json['port'];
    if (port is! int) return null;
    return PortInfo(
      port: port,
      pid: json['pid'] as int?,
      processName: json['processName'] as String?,
      label: json['label'] as String?,
      scheme: json['scheme'] as String?,
    );
  }
}

class PreviewState {
  final List<PortInfo> ports;
  final int? selectedPort;
  final int? localProxyPort;
  final String? currentUrl;

  /// Scheme of the selected target ('http' or 'https'). Drives the webview
  /// origin in direct/local mode and is forwarded to the bridge in relay mode.
  final String scheme;
  final bool isLoading;
  final String? error;

  const PreviewState({
    this.ports = const [],
    this.selectedPort,
    this.localProxyPort,
    this.currentUrl,
    this.scheme = 'http',
    this.isLoading = false,
    this.error,
  });

  PreviewState copyWith({
    List<PortInfo>? ports,
    int? selectedPort,
    bool clearSelectedPort = false,
    int? localProxyPort,
    bool clearLocalProxyPort = false,
    String? currentUrl,
    bool clearCurrentUrl = false,
    String? scheme,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return PreviewState(
      ports: ports ?? this.ports,
      selectedPort: clearSelectedPort
          ? null
          : (selectedPort ?? this.selectedPort),
      localProxyPort: clearLocalProxyPort
          ? null
          : (localProxyPort ?? this.localProxyPort),
      currentUrl: clearCurrentUrl ? null : (currentUrl ?? this.currentUrl),
      scheme: scheme ?? this.scheme,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// `bodyEncoding` for a base64-of-gzip response body. Mirrors
/// `TUNNEL_GZIP_ENCODING` in the bridge's `tunnel-protocol.ts`.
///
/// Compressing inside the tunnel message is the only compression available
/// here: the relay carries AES-GCM ciphertext, which WebSocket
/// permessage-deflate cannot squeeze.
const String kTunnelGzipEncoding = 'gzip-base64';

class TunnelHttpRequest {
  final String requestId;
  final int port;

  /// Target dev-server scheme ('http' or 'https'). The bridge fetches the
  /// local dev server over this scheme; the local preview proxy that fronts
  /// the webview is always plain HTTP regardless.
  final String scheme;
  final String method;
  final String path;
  final Map<String, String> headers;
  final String? body;

  /// Body encodings we can decode beyond the mandatory utf8/base64. A bridge
  /// that predates this field ignores it and answers uncompressed, which is
  /// why an unknown `bodyEncoding` can never reach us unrequested.
  final List<String> acceptEncodings;

  const TunnelHttpRequest({
    required this.requestId,
    required this.port,
    this.scheme = 'http',
    required this.method,
    required this.path,
    required this.headers,
    this.body,
    this.acceptEncodings = const [kTunnelGzipEncoding],
  });

  Map<String, dynamic> toJson() {
    return {
      'type': 'tunnel:http-request',
      'requestId': requestId,
      'port': port,
      'scheme': scheme,
      'method': method,
      'path': path,
      'headers': headers,
      if (body != null) 'body': body,
      if (acceptEncodings.isNotEmpty) 'acceptEncodings': acceptEncodings,
    };
  }
}

class TunnelHttpResponse {
  final String requestId;
  final int status;
  final Map<String, String> headers;

  /// Set-Cookie values carried out-of-band: a single response can set several,
  /// and [headers] (a string map) can only hold one. Emitted as repeated
  /// Set-Cookie headers by the proxy.
  final List<String> setCookies;
  final String body;
  final String bodyEncoding;

  const TunnelHttpResponse({
    required this.requestId,
    required this.status,
    required this.headers,
    this.setCookies = const [],
    required this.body,
    required this.bodyEncoding,
  });

  static TunnelHttpResponse? fromJson(Map<String, dynamic> json) {
    final requestId = json['requestId'];
    final status = json['status'];
    final body = json['body'];
    final bodyEncoding = json['bodyEncoding'];
    if (requestId is! String ||
        status is! int ||
        body is! String ||
        bodyEncoding is! String) {
      return null;
    }

    final headersJson = json['headers'];
    final headers = <String, String>{};
    if (headersJson is Map) {
      for (final entry in headersJson.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }

    final setCookies =
        (json['setCookies'] as List?)?.whereType<String>().toList() ??
        const <String>[];

    return TunnelHttpResponse(
      requestId: requestId,
      status: status,
      headers: headers,
      setCookies: setCookies,
      body: body,
      bodyEncoding: bodyEncoding,
    );
  }
}

class PortsUpdateMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final List<PortInfo> ports;

  const PortsUpdateMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.ports,
  });
}
