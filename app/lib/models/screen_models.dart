/// Dart mirrors of the bridge's `screen:*` agent messages
/// (`bridge/src/protocol.ts`) — WebRTC signalling for the native-window
/// preview. Kept in lockstep with the Zod schemas there.
///
/// Only the signalling rides these frames. The media track and the input
/// datachannel are peer-to-peer between the two app processes and never reach
/// the bridge or the relay, so nothing here describes a frame or an input
/// event.
///
/// Every frame carries an optional `viewerId`: the Iroh peer id of the viewer's
/// connection, meaningful only on the loopback leg between the bridge and the
/// capture host. The bridge stamps it onto each frame a viewer sends,
/// overwriting whatever the viewer put there, and delivers a host frame only to
/// the peer it names — dropping one that names nobody. So a viewer never sets
/// it, and the host must set it on everything it sends.
library;

/// `viewerId` off the wire, treating an empty or non-string value as absent —
/// the bridge's schema rejects an empty one, so it can never name a viewer.
String? _viewerIdOf(Map<String, dynamic> json) {
  final viewerId = json['viewerId'];
  return viewerId is String && viewerId.isNotEmpty ? viewerId : null;
}

/// Wire values of `screen:state.status`.
enum ScreenSessionStatus {
  idle,

  /// The desktop capture app is not connected to the bridge over loopback, so
  /// there is nobody to answer a request. The viewer must surface this rather
  /// than keep waiting — the bridge answers it precisely because a request with
  /// no host would otherwise never be replied to at all.
  noHost,
  awaitingConsent,
  live,

  /// The peer connection lost its path and is trying to recover. Distinct from
  /// `live` because the viewer would otherwise keep rendering the last frame it
  /// received, and distinct from `ended` because ICE recovers from this on its
  /// own after any ordinary network change.
  interrupted,
  ended,
}

const Map<String, ScreenSessionStatus> _statusByWire = {
  'idle': ScreenSessionStatus.idle,
  'no-host': ScreenSessionStatus.noHost,
  'awaiting-consent': ScreenSessionStatus.awaitingConsent,
  'live': ScreenSessionStatus.live,
  'interrupted': ScreenSessionStatus.interrupted,
  'ended': ScreenSessionStatus.ended,
};

const Map<ScreenSessionStatus, String> _wireByStatus = {
  ScreenSessionStatus.idle: 'idle',
  ScreenSessionStatus.noHost: 'no-host',
  ScreenSessionStatus.awaitingConsent: 'awaiting-consent',
  ScreenSessionStatus.live: 'live',
  ScreenSessionStatus.interrupted: 'interrupted',
  ScreenSessionStatus.ended: 'ended',
};

/// The wire value for [status]. Exposed so an outbound builder that assembles a
/// `screen:state` payload by hand shares this table rather than growing a second
/// copy that can drift from it.
String screenStatusWire(ScreenSessionStatus status) => _wireByStatus[status]!;

/// Which end of a session picks the window.
enum ScreenChooser {
  /// The person at the machine picks, from a local dialog. The request names no
  /// window and the host publishes no catalog.
  host,

  /// The requesting device picks, from the catalog the host publishes in answer.
  /// For a machine with nobody sitting at it, this is the only workable order.
  viewer,
}

const Map<String, ScreenChooser> _chooserByWire = {
  'host': ScreenChooser.host,
  'viewer': ScreenChooser.viewer,
};

const Map<ScreenChooser, String> _wireByChooser = {
  ScreenChooser.host: 'host',
  ScreenChooser.viewer: 'viewer',
};

/// Viewer → host. Asks for a session.
///
/// It never names a window: even when [chooser] is [ScreenChooser.viewer] the
/// pick is a second frame, sent against a catalog the host chose to publish.
class ScreenRequestMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final String projectId;

  /// Absent on the wire means [ScreenChooser.host] — that is what a client from
  /// before viewer-side picking sends, and silence must keep meaning the old
  /// behaviour rather than the new one.
  final ScreenChooser chooser;

  const ScreenRequestMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.projectId,
    this.chooser = ScreenChooser.host,
  });

  static ScreenRequestMessage? fromJson(Map<String, dynamic> json) {
    final projectId = json['projectId'];
    if (projectId is! String) return null;
    return ScreenRequestMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      projectId: projectId,
      chooser: _chooserByWire[json['chooser']] ?? ScreenChooser.host,
    );
  }

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'chooser': _wireByChooser[chooser],
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// One entry of the catalog a viewer picks from.
///
/// No thumbnail, unlike the local [ScreenWindow] this is built from: a thumbnail
/// is a picture of a window nobody has agreed to share yet, so the catalog would
/// disclose more than the session it exists to start.
class ScreenWindowEntry {
  final String id;
  final String title;

  /// Whether picking this one will un-minimise it on the host machine.
  ///
  /// Disclosed rather than silently done: restoring a window is a visible
  /// change to somebody else's desktop, and the viewer is the only end that can
  /// decide it is worth making.
  final bool minimised;

  const ScreenWindowEntry({
    required this.id,
    required this.title,
    this.minimised = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (minimised) 'minimised': true,
  };
}

/// Host → viewer. Sent only in answer to a [ScreenChooser.viewer] request.
class ScreenWindowsMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final List<ScreenWindowEntry> windows;

  const ScreenWindowsMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.windows,
  });

  static ScreenWindowsMessage? fromJson(Map<String, dynamic> json) {
    final raw = json['windows'];
    if (raw is! List) return null;
    final windows = <ScreenWindowEntry>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final title = entry['title'];
      if (id is! String || title is! String) continue;
      windows.add(
        ScreenWindowEntry(
          id: id,
          title: title,
          minimised: entry['minimised'] == true,
        ),
      );
    }
    return ScreenWindowsMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      windows: windows,
    );
  }

  Map<String, dynamic> toJson() => {
    'windows': [for (final w in windows) w.toJson()],
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Viewer → host. Names one window out of the catalog just published.
///
/// The host checks the id against that catalog before capturing anything; a
/// window it never offered cannot be reached by naming it here.
class ScreenPickMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final String windowId;

  const ScreenPickMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.windowId,
  });

  static ScreenPickMessage? fromJson(Map<String, dynamic> json) {
    final windowId = json['windowId'];
    if (windowId is! String) return null;
    return ScreenPickMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      windowId: windowId,
    );
  }

  Map<String, dynamic> toJson() => {
    'windowId': windowId,
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Host → viewer.
class ScreenStateMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final ScreenSessionStatus status;
  final String? reason;
  final String? windowTitle;
  final int? width;
  final int? height;

  const ScreenStateMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.status,
    this.reason,
    this.windowTitle,
    this.width,
    this.height,
  });

  static ScreenStateMessage? fromJson(Map<String, dynamic> json) {
    final status = _statusByWire[json['status']];
    if (status == null) return null;
    return ScreenStateMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      status: status,
      reason: json['reason'] as String?,
      windowTitle: json['windowTitle'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'status': _wireByStatus[status],
    if (reason != null) 'reason': reason,
    if (windowTitle != null) 'windowTitle': windowTitle,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Host → viewer.
class ScreenOfferMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final String sdp;

  /// The DTLS fingerprint of the offer, carried inside the lease-authenticated
  /// Iroh connection so the media session binds to an endpoint the
  /// authorization already named. The viewer must verify it against the
  /// negotiated one and abort on mismatch — DTLS-SRTP is a second crypto path,
  /// and that check is what stops a party able to rewrite signalling from
  /// substituting its own certificate.
  final String dtlsFingerprint;
  final int width;
  final int height;

  const ScreenOfferMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.sdp,
    required this.dtlsFingerprint,
    required this.width,
    required this.height,
  });

  static ScreenOfferMessage? fromJson(Map<String, dynamic> json) {
    final sdp = json['sdp'];
    final dtlsFingerprint = json['dtlsFingerprint'];
    final width = json['width'];
    final height = json['height'];
    if (sdp is! String ||
        dtlsFingerprint is! String ||
        width is! int ||
        height is! int) {
      return null;
    }
    return ScreenOfferMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      sdp: sdp,
      dtlsFingerprint: dtlsFingerprint,
      width: width,
      height: height,
    );
  }

  Map<String, dynamic> toJson() => {
    'sdp': sdp,
    'dtlsFingerprint': dtlsFingerprint,
    'width': width,
    'height': height,
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Viewer → host.
class ScreenAnswerMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final String sdp;
  final String dtlsFingerprint;

  const ScreenAnswerMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.sdp,
    required this.dtlsFingerprint,
  });

  static ScreenAnswerMessage? fromJson(Map<String, dynamic> json) {
    final sdp = json['sdp'];
    final dtlsFingerprint = json['dtlsFingerprint'];
    if (sdp is! String || dtlsFingerprint is! String) return null;
    return ScreenAnswerMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      sdp: sdp,
      dtlsFingerprint: dtlsFingerprint,
    );
  }

  Map<String, dynamic> toJson() => {
    'sdp': sdp,
    'dtlsFingerprint': dtlsFingerprint,
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Both directions.
class ScreenIceMessage {
  final String id;
  final int timestamp;
  final String? viewerId;

  /// An empty string is the end-of-candidates signal, so emptiness is not an
  /// error here.
  final String candidate;

  /// libwebrtc supplies one or both of these; an index of 0 is meaningful, so
  /// neither may be collapsed into a falsy check.
  final String? sdpMid;
  final int? sdpMLineIndex;

  const ScreenIceMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  static ScreenIceMessage? fromJson(Map<String, dynamic> json) {
    final candidate = json['candidate'];
    if (candidate is! String) return null;
    return ScreenIceMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      candidate: candidate,
      sdpMid: json['sdpMid'] as String?,
      sdpMLineIndex: json['sdpMLineIndex'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'candidate': candidate,
    if (sdpMid != null) 'sdpMid': sdpMid,
    if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Both directions.
class ScreenStopMessage {
  final String id;
  final int timestamp;
  final String? viewerId;
  final String reason;

  const ScreenStopMessage({
    required this.id,
    required this.timestamp,
    this.viewerId,
    required this.reason,
  });

  static ScreenStopMessage? fromJson(Map<String, dynamic> json) {
    final reason = json['reason'];
    if (reason is! String) return null;
    return ScreenStopMessage(
      id: json['id'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
      viewerId: _viewerIdOf(json),
      reason: reason,
    );
  }

  Map<String, dynamic> toJson() => {
    'reason': reason,
    if (viewerId != null) 'viewerId': viewerId,
  };
}

/// Parse one `screen:*` frame. Returns null for an unknown type or a malformed
/// payload, matching `parseAbMessage`'s contract.
Object? parseScreenMessage(Map<String, dynamic> json) {
  switch (json['type']) {
    case 'screen:request':
      return ScreenRequestMessage.fromJson(json);
    case 'screen:windows':
      return ScreenWindowsMessage.fromJson(json);
    case 'screen:pick':
      return ScreenPickMessage.fromJson(json);
    case 'screen:state':
      return ScreenStateMessage.fromJson(json);
    case 'screen:offer':
      return ScreenOfferMessage.fromJson(json);
    case 'screen:answer':
      return ScreenAnswerMessage.fromJson(json);
    case 'screen:ice':
      return ScreenIceMessage.fromJson(json);
    case 'screen:stop':
      return ScreenStopMessage.fromJson(json);
    default:
      return null;
  }
}
