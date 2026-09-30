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

  /// Scheme the dev server speaks ('http' or 'https'). In relay mode it comes
  /// from the bridge's TLS probe rather than from the detected hint.
  final String scheme;

  /// The localhost port the webview loads. Equals [port] in local mode and in
  /// relay mode unless that port was already taken on this device.
  final int? localPort;

  /// URL the webview should load, on [localPort].
  final String? currentUrl;

  const PreviewTab({
    required this.port,
    required this.scheme,
    this.localPort,
    this.currentUrl,
  });

  PreviewTab copyWith({
    String? scheme,
    int? localPort,
    bool clearLocalPort = false,
    String? currentUrl,
    bool clearCurrentUrl = false,
  }) {
    return PreviewTab(
      port: port,
      scheme: scheme ?? this.scheme,
      localPort: clearLocalPort
          ? null
          : (localPort ?? this.localPort),
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
