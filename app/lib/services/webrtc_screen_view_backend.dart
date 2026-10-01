import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'screen_ice_config.dart';
import 'screen_share_backend.dart';
import 'screen_view_backend.dart';
import 'webrtc_screen_backend.dart'
    show
        kFastInputChannelLabel,
        kReliableInputChannelLabel,
        readRemoteDtlsFingerprint;

/// The [ScreenViewBackend] built on flutter_webrtc.
class WebrtcScreenViewBackend implements ScreenViewBackend {
  const WebrtcScreenViewBackend({this.iceServers = defaultIceServers});

  /// Each peer resolves its own servers. ICE does not need the two lists to
  /// agree, only for one candidate pair between the peers to connect.
  final IceServerResolver iceServers;

  @override
  Future<ScreenViewPeer> createPeer() async {
    final servers = await resolveIceServersOrStun(iceServers);
    final pc = await createPeerConnection({
      'iceServers': encodeIceServers(servers),
      'sdpSemantics': 'unified-plan',
    });
    final peer = _WebrtcScreenViewPeer(pc);
    try {
      await peer.start();
      return peer;
    } catch (_) {
      await peer.dispose();
      rethrow;
    }
  }
}

class _WebrtcScreenViewPeer implements ScreenViewPeer {
  _WebrtcScreenViewPeer(this._pc);

  final RTCPeerConnection _pc;
  final _renderer = RTCVideoRenderer();

  final _candidates = StreamController<ScreenIceCandidate>.broadcast();
  final _peerStates = StreamController<ScreenPeerState>.broadcast();
  final _frameSizes = StreamController<ScreenFrameSize>.broadcast();

  RTCDataChannel? _fast;
  RTCDataChannel? _reliable;
  Widget? _videoView;
  bool _disposed = false;

  @override
  Stream<ScreenIceCandidate> get localCandidates => _candidates.stream;

  @override
  Stream<ScreenPeerState> get peerStates => _peerStates.stream;

  @override
  Stream<ScreenFrameSize> get frameSizes => _frameSizes.stream;

  @override
  Widget? get videoView => _videoView;

  Future<void> start() async {
    await _renderer.initialize();
    _renderer.onResize = _publishSize;
    _renderer.onFirstFrameRendered = _publishSize;

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
    _pc.onTrack = (event) {
      if (_disposed || event.streams.isEmpty) return;
      _renderer.srcObject = event.streams.first;
      // The view is built once, here, and handed out by reference — rebuilding
      // it per frame would re-create the platform texture on every resize.
      _videoView ??= RTCVideoView(
        _renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    };
    // The host is the offerer and creates both channels, so the viewer only
    // adopts them by label.
    _pc.onDataChannel = (channel) {
      switch (channel.label) {
        case kFastInputChannelLabel:
          _fast = channel;
        case kReliableInputChannelLabel:
          _reliable = channel;
      }
    };
  }

  void _publishSize() {
    if (_frameSizes.isClosed) return;
    final width = _renderer.videoWidth;
    final height = _renderer.videoHeight;
    if (width <= 0 || height <= 0) return;
    _frameSizes.add(ScreenFrameSize(width, height));
  }

  @override
  Future<ScreenSdp> answerOffer(String offerSdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await _pc.createAnswer({});
    await _pc.setLocalDescription(answer);
    final sdp = answer.sdp ?? '';
    final fingerprint = parseDtlsFingerprint(sdp);
    if (fingerprint == null) {
      throw StateError('answer carries no DTLS fingerprint');
    }
    return ScreenSdp(sdp: sdp, dtlsFingerprint: fingerprint);
  }

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
  bool sendInput(String payload, {required bool reliable}) {
    final channel = reliable ? _reliable : (_fast ?? _reliable);
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    channel.send(RTCDataChannelMessage(payload));
    return true;
  }

  @override
  Future<String?> remoteFingerprint() => readRemoteDtlsFingerprint(_pc);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pc.onIceCandidate = null;
    _pc.onConnectionState = null;
    _pc.onTrack = null;
    _pc.onDataChannel = null;
    _renderer.onResize = null;
    _renderer.onFirstFrameRendered = null;
    _videoView = null;
    await _fast?.close();
    await _reliable?.close();
    await _pc.close();
    await _pc.dispose();
    _renderer.srcObject = null;
    await _renderer.dispose();
    await _candidates.close();
    await _peerStates.close();
    await _frameSizes.close();
  }
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

/// The viewer backend for this platform, or null where it cannot run.
///
/// Unlike hosting, viewing is available everywhere the plugin has a native
/// build — a phone has no window to share but is the device this feature exists
/// for. Web is excluded because the desktop app is the only shell we ship.
ScreenViewBackend? createScreenViewBackend() =>
    kIsWeb ? null : const WebrtcScreenViewBackend();
