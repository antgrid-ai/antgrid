class PortInfo {
  final int port;
  final int? pid;
  final String? processName;
  final String? label;

  /// Dev-server scheme detected by the bridge ('http'/'https'). Null when the
  /// bridge hasn't seen a URL for this port yet — treat as http.
  final String? scheme;

  /// Config-declared `onDetect` behavior ('notify'/'openPreview'/'silent'/
  ///'ignore'). Null for a port the bridge only knows from terminal output —
  /// treat that the same as 'notify' (the config default).
  final String? onDetect;

  const PortInfo({
    required this.port,
    this.pid,
    this.processName,
    this.label,
    this.scheme,
    this.onDetect,
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
      onDetect: json['onDetect'] as String?,
    );
  }
}

/// One open preview tab. [port] is the tab's stable identity — one dev
/// server per port — so opening an already-open port is a lookup, never a
/// second tab.
class PreviewTab {
  final int port;

  /// Scheme of the target dev server ('http' or 'https'). Drives the webview
  /// origin in direct/local mode and is forwarded to the bridge in relay mode.
  final String scheme;

  /// Null while a relay-mode proxy bind is in flight; equals [port] in local
  /// mode (no proxy — the webview hits localhost directly).
  final int? localProxyPort;

  /// Origin the webview should load: the proxy origin in relay mode, the
  /// logical `scheme://localhost:port` origin in local mode.
  final String? currentUrl;

  const PreviewTab({
    required this.port,
    required this.scheme,
    this.localProxyPort,
    this.currentUrl,
  });

  PreviewTab copyWith({
    String? scheme,
    int? localProxyPort,
    bool clearLocalProxyPort = false,
    String? currentUrl,
    bool clearCurrentUrl = false,
  }) {
    return PreviewTab(
      port: port,
      scheme: scheme ?? this.scheme,
      localProxyPort: clearLocalProxyPort
          ? null
          : (localProxyPort ?? this.localProxyPort),
      currentUrl: clearCurrentUrl ? null : (currentUrl ?? this.currentUrl),
    );
  }
}

class PreviewState {
  final List<PortInfo> ports;

  /// Open tabs, in open-order. One entry per previewed port.
  final List<PreviewTab> tabs;

  /// The focused tab's port, or null when [tabs] is empty.
  final int? activeTabId;

  final bool isLoading;
  final String? error;

  const PreviewState({
    this.ports = const [],
    this.tabs = const [],
    this.activeTabId,
    this.isLoading = false,
    this.error,
  });

  PreviewTab? get activeTab {
    final id = activeTabId;
    if (id == null) return null;
    for (final tab in tabs) {
      if (tab.port == id) return tab;
    }
    return null;
  }

  PreviewState copyWith({
    List<PortInfo>? ports,
    List<PreviewTab>? tabs,
    int? activeTabId,
    bool clearActiveTabId = false,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return PreviewState(
      ports: ports ?? this.ports,
      tabs: tabs ?? this.tabs,
      activeTabId: clearActiveTabId
          ? null
          : (activeTabId ?? this.activeTabId),
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

/// Inbound half of the WS tunnel (mirrors `TunnelWsData` in the bridge's
/// `tunnel-protocol.ts`) — a frame the upstream dev-server sent, to relay
/// into the local WebSocket the previewed page holds open. [binary] mirrors
/// the frame's own text/binary distinction: absent/false means [data] is
/// UTF-8 text verbatim, true means it is base64 of the raw bytes.
class TunnelWsDataMessage {
  final String tunnelId;
  final String data;
  final bool binary;

  const TunnelWsDataMessage({
    required this.tunnelId,
    required this.data,
    this.binary = false,
  });

  static TunnelWsDataMessage? fromJson(Map<String, dynamic> json) {
    final tunnelId = json['tunnelId'];
    final data = json['data'];
    if (tunnelId is! String || data is! String) return null;
    return TunnelWsDataMessage(
      tunnelId: tunnelId,
      data: data,
      binary: json['binary'] == true,
    );
  }
}

/// The bridge's side of a WS tunnel closed (the upstream dev-server
/// connection ended) — mirror the close onto the local WebSocket.
class TunnelWsCloseMessage {
  final String tunnelId;

  const TunnelWsCloseMessage({required this.tunnelId});

  static TunnelWsCloseMessage? fromJson(Map<String, dynamic> json) {
    final tunnelId = json['tunnelId'];
    if (tunnelId is! String) return null;
    return TunnelWsCloseMessage(tunnelId: tunnelId);
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

/// Config-declared behavior for a detected port ('notify'/'openPreview' both
/// drive auto-open today — see [PreviewService._handlePortDetected]; 'silent'
/// lists the port without opening it; 'ignore' never reaches the app — the
/// bridge filters it before sending `port:detected`).
class PortDetectedAttributes {
  final String? name;
  final String onDetect;

  const PortDetectedAttributes({this.name, this.onDetect = 'notify'});
}

/// A single fresh port sighting (mirrors `PortDetectedMessage` in the
/// bridge's `protocol.ts`). One event per genuinely new detection — unlike
/// [PortsUpdateMessage], which is a full re-sent snapshot on every reconnect.
class PortDetectedMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final int port;
  final String url;
  final String scheme;
  final String source;
  final String? sourceSessionId;
  final PortDetectedAttributes attributes;

  const PortDetectedMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.port,
    required this.url,
    required this.scheme,
    required this.source,
    this.sourceSessionId,
    required this.attributes,
  });
}
