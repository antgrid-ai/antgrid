import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../native/win32_input.dart' show enumerateMinimisedWindows;
import 'screen_ice_config.dart';
import 'screen_share_backend.dart';

/// Encoder tuning, measured rather than guessed (see
/// `docs/plans/2026-08-01-native-app-preview.md` §3).
///
/// libwebrtc treats a screen share as camera video and downscales hard to
/// protect smoothness: the defaults produce 362x225, which is unreadable for
/// testing a UI and reads as a broken feature. `MAINTAIN_RESOLUTION` plus an
/// explicit bitrate floor took the same window to 1448x903, trading 20 fps for
/// 15. The usual `track.contentHint = 'text'` lever is unavailable — it exists
/// inside the DLL but is not surfaced in the flutter_webrtc Dart API — so this
/// is the whole of it.
const int kScreenShareMaxBitrate = 8000000;
const int kScreenShareMinBitrate = 1000000;

const String kFastInputChannelLabel = 'antgrid-input-fast';
const String kReliableInputChannelLabel = 'antgrid-input';

/// The [ScreenShareBackend] built on flutter_webrtc. Desktop only — nothing here
/// runs under `flutter test`, which is why the service talks to the interface.
class WebrtcScreenBackend implements ScreenShareBackend {
  WebrtcScreenBackend({this.iceServers = defaultIceServers});

  /// Resolved afresh for every session; see [IceServerResolver].
  final IceServerResolver iceServers;

  final _windowUpdates = StreamController<ScreenWindow>.broadcast();
  StreamSubscription<DesktopCapturerSource>? _thumbnailSub;
  StreamSubscription<DesktopCapturerSource>? _nameSub;

  final Map<String, DesktopCapturerSource> _sources = {};
  bool _disposed = false;

  @override
  Stream<ScreenWindow> get windowUpdates => _windowUpdates.stream;

  @override
  Future<List<ScreenWindow>> listWindows() async {
    // Subscribe before enumerating: the thumbnail for a source can land between
    // the platform call returning and this listener attaching, and a picker that
    // missed it would show a blank tile until the next enumeration.
    _bindSourceEvents();
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Window],
      thumbnailSize: ThumbnailSize(320, 180),
    );
    _sources
      ..clear()
      ..addEntries(sources.map((s) => MapEntry(s.id, s)));
    final windows = sources.map(_toWindow).toList();
    // libwebrtc omits minimised windows because it cannot capture one; we
    // restore before capturing, so the omission would only hide the windows a
    // remote peer most needs. Appended rather than merged: nothing here is in
    // `sources`, precisely because that call dropped them.
    for (final window in enumerateMinimisedWindows()) {
      final id = '${window.hwnd}';
      if (_sources.containsKey(id)) continue;
      windows.add(ScreenWindow(id: id, title: window.title, minimised: true));
    }
    return List.unmodifiable(windows);
  }

  void _bindSourceEvents() {
    _thumbnailSub ??= desktopCapturer.onThumbnailChanged.stream.listen((s) {
      _sources[s.id] = s;
      if (!_windowUpdates.isClosed) _windowUpdates.add(_toWindow(s));
    });
    _nameSub ??= desktopCapturer.onNameChanged.stream.listen((s) {
      _sources[s.id] = s;
      if (!_windowUpdates.isClosed) _windowUpdates.add(_toWindow(s));
    });
  }

  ScreenWindow _toWindow(DesktopCapturerSource s) =>
      ScreenWindow(id: s.id, title: s.name, thumbnail: s.thumbnail);

  @override
  Future<ScreenSharePeer> startShare(String windowId) async {
    // A window that was minimised when the catalog was built is absent from the
    // plugin's own source list, and `getDisplayMedia` answers an unknown id with
    // "source not found". The caller has restored it by now, so one more
    // enumeration is what makes libwebrtc admit it exists.
    if (!_sources.containsKey(windowId)) await listWindows();
    final title = _sources[windowId]?.name ?? '';
    final stream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'deviceId': {'exact': windowId},
        'mandatory': {'frameRate': 30.0},
      },
    });
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      await stream.dispose();
      throw StateError('capture produced no video track for window $windowId');
    }

    final servers = await resolveIceServersOrStun(iceServers);

    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection({
        'iceServers': encodeIceServers(servers),
        'sdpSemantics': 'unified-plan',
      });
      final peer = _WebrtcScreenSharePeer(
        pc: pc,
        stream: stream,
        track: videoTracks.first,
        windowTitle: title,
      );
      await peer.start();
      return peer;
    } catch (_) {
      await pc?.dispose();
      await stream.dispose();
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _thumbnailSub?.cancel();
    _thumbnailSub = null;
    await _nameSub?.cancel();
    _nameSub = null;
    _sources.clear();
    await _windowUpdates.close();
  }
}

class _WebrtcScreenSharePeer implements ScreenSharePeer {
  _WebrtcScreenSharePeer({
    required RTCPeerConnection pc,
    required MediaStream stream,
    required MediaStreamTrack track,
    required this.windowTitle,
  }) : _pc = pc,
       _stream = stream,
       _track = track;

  final RTCPeerConnection _pc;
  final MediaStream _stream;
  final MediaStreamTrack _track;

  @override
  final String windowTitle;

  final _candidates = StreamController<ScreenIceCandidate>.broadcast();
  final _peerStates = StreamController<ScreenPeerState>.broadcast();
  final _inputMessages = StreamController<String>.broadcast();
  final _captureEnded = StreamController<void>.broadcast();

  RTCRtpSender? _sender;
  RTCDataChannel? _fast;
  RTCDataChannel? _reliable;
  ScreenFrameSize _initialFrameSize = const ScreenFrameSize(0, 0);
  bool _disposed = false;

  @override
  ScreenFrameSize get initialFrameSize => _initialFrameSize;

  @override
  Stream<ScreenIceCandidate> get localCandidates => _candidates.stream;

  @override
  Stream<ScreenPeerState> get peerStates => _peerStates.stream;

  @override
  Stream<String> get inputMessages => _inputMessages.stream;

  @override
  Stream<void> get captureEnded => _captureEnded.stream;

  Future<void> start() async {
    _pc.onIceCandidate = (c) {
      if (_candidates.isClosed) return;
      _candidates.add(
        ScreenIceCandidate(
          candidate: c.candidate ?? '',
          sdpMid: c.sdpMid,
          sdpMLineIndex: c.sdpMLineIndex,
        ),
      );
    };
    _pc.onConnectionState = (s) {
      if (_peerStates.isClosed) return;
      _peerStates.add(_mapPeerState(s));
    };
    _track.onEnded = () {
      if (!_captureEnded.isClosed) _captureEnded.add(null);
    };

    // Both channels are created here, by the offerer, so they are negotiated in
    // the same exchange as the media and the viewer only has to accept them.
    _fast = await _pc.createDataChannel(
      kFastInputChannelLabel,
      RTCDataChannelInit()
        ..ordered = false
        // Zero retransmits, not a lifetime: a stale mouse position is worse
        // than a missing one, and the next sample supersedes it anyway.
        ..maxRetransmits = 0,
    );
    _reliable = await _pc.createDataChannel(
      kReliableInputChannelLabel,
      RTCDataChannelInit()..ordered = true,
    );
    for (final channel in [_fast, _reliable]) {
      channel?.onMessage = (msg) {
        if (msg.isBinary || _inputMessages.isClosed) return;
        _inputMessages.add(msg.text);
      };
    }

    _sender = await _pc.addTrack(_track, _stream);
    await _applyEncoderTuning();
    _initialFrameSize = _readTrackSize();
  }

  /// The measured tuning from findings §3. Failing to apply it is not fatal —
  /// the session still works, just at an unreadable resolution — but it is worth
  /// a log, because that is exactly what "the feature is broken" looks like.
  Future<void> _applyEncoderTuning() async {
    final sender = _sender;
    if (sender == null) return;
    try {
      final params = sender.parameters;
      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        // A sender with no encoding entry would silently keep the defaults, so
        // seed one rather than leave the bitrate floor unapplied.
        params.encodings = [
          RTCRtpEncoding(
            maxBitrate: kScreenShareMaxBitrate,
            minBitrate: kScreenShareMinBitrate,
          ),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = kScreenShareMaxBitrate;
          encoding.minBitrate = kScreenShareMinBitrate;
        }
      }
      await sender.setParameters(params);
    } catch (err) {
      developer.log(
        'screen share: encoder tuning rejected, capture will downscale: $err',
        name: 'antgrid.screen',
      );
    }
  }

  ScreenFrameSize _readTrackSize() {
    try {
      final settings = _track.getSettings();
      final width = settings['width'];
      final height = settings['height'];
      if (width is num && height is num && width > 0 && height > 0) {
        return ScreenFrameSize(width.toInt(), height.toInt());
      }
    } catch (_) {
      // getSettings is optional per platform; the stats poll is authoritative.
    }
    return const ScreenFrameSize(0, 0);
  }

  @override
  Future<ScreenSdp> createOffer() async {
    final offer = await _pc.createOffer({});
    await _pc.setLocalDescription(offer);
    final sdp = offer.sdp ?? '';
    final fingerprint = parseDtlsFingerprint(sdp);
    if (fingerprint == null) {
      throw StateError('offer carries no DTLS fingerprint');
    }
    return ScreenSdp(sdp: sdp, dtlsFingerprint: fingerprint);
  }

  @override
  Future<void> acceptAnswer(String sdp) =>
      _pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

  @override
  Future<void> addRemoteCandidate(ScreenIceCandidate candidate) =>
      _pc.addCandidate(
        RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );

  @override
  Future<ScreenFrameSize?> encodedFrameSize() async {
    final sender = _sender;
    if (sender == null) return null;
    try {
      for (final report in await sender.getStats()) {
        if (report.type != 'outbound-rtp') continue;
        final width = report.values['frameWidth'];
        final height = report.values['frameHeight'];
        // Absent until a frame has actually been encoded — an `outbound-rtp`
        // with `framesEncoded: 0` carries neither, which is what a capture that
        // never started looks like from here.
        if (width is num && height is num) {
          return ScreenFrameSize(width.toInt(), height.toInt());
        }
      }
    } catch (_) {
      // A stats call racing teardown throws; the caller reads null as "unknown"
      // and simply asks again on the next tick.
    }
    return null;
  }

  @override
  Future<String?> remoteFingerprint() => readRemoteDtlsFingerprint(_pc);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Close the peer connection before the capture: it is what carries remote
    // input, so it must stop first when this is a revocation rather than an
    // ordinary end of session.
    _pc.onIceCandidate = null;
    _pc.onConnectionState = null;
    await _fast?.close();
    await _reliable?.close();
    await _pc.close();
    await _pc.dispose();
    _track.onEnded = null;
    await _track.stop();
    await _stream.dispose();
    await _candidates.close();
    await _peerStates.close();
    await _inputMessages.close();
    await _captureEnded.close();
  }
}

/// The fingerprint of the certificate the remote peer presented, read out of the
/// transport statistics — `sha-256 AB:CD:…` where the algorithm is reported, the
/// bare digest where it is not.
///
/// This is the certificate DTLS actually verified against, so it is the only
/// value that says what the media path is really bound to; the SDP only says
/// what was asked for. Null means "not known yet": the transport has no remote
/// certificate until the handshake completes, and a session that is still
/// connecting must not be read as one that failed verification.
Future<String?> readRemoteDtlsFingerprint(RTCPeerConnection pc) async {
  try {
    final reports = await pc.getStats();
    String? certificateId;
    for (final report in reports) {
      if (report.type != 'transport') continue;
      final id = report.values['remoteCertificateId'];
      if (id is String && id.isNotEmpty) {
        certificateId = id;
        break;
      }
    }
    if (certificateId == null) return null;
    for (final report in reports) {
      if (report.id != certificateId) continue;
      final fingerprint = report.values['fingerprint'];
      if (fingerprint is! String || fingerprint.isEmpty) return null;
      final algorithm = report.values['fingerprintAlgorithm'];
      return algorithm is String && algorithm.isNotEmpty
          ? '$algorithm $fingerprint'
          : fingerprint;
    }
  } catch (_) {
    // A stats call racing teardown throws; the caller reads null as "unknown"
    // and asks again.
  }
  return null;
}

ScreenPeerState _mapPeerState(RTCPeerConnectionState state) => switch (state) {
  RTCPeerConnectionState.RTCPeerConnectionStateNew ||
  RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
    ScreenPeerState.connecting,
  RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
    ScreenPeerState.connected,
  RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
    ScreenPeerState.disconnected,
  RTCPeerConnectionState.RTCPeerConnectionStateFailed => ScreenPeerState.failed,
  RTCPeerConnectionState.RTCPeerConnectionStateClosed => ScreenPeerState.closed,
};

/// The backend for this OS, or null where hosting is not available.
///
/// Windows only, deliberately: mobile has no windows to share, and macOS is
/// gated on two unanswered questions — whether libwebrtc still reaches a working
/// window capturer now that `CGWindowListCreateImage` is obsoleted, and whether
/// a backgrounded app can raise another app's window at all. Enabling it here
/// before those are measured would ship a picker that produces black frames.
ScreenShareBackend? createScreenShareBackend() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => WebrtcScreenBackend(),
    _ => null,
  };
}
