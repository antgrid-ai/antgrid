import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Widget;

import '../models/ab_message.dart';
import '../models/screen_models.dart';
import '../project/project_session.dart';
import 'screen_share_backend.dart';
import 'screen_view_backend.dart';
import 'screen_viewer_input.dart';
import 'webrtc_screen_view_backend.dart';

/// Where an inbound screen session is from the viewer's side.
///
/// Every `ScreenSessionStatus` on the wire lands on one of these, plus the two
/// transitions the wire does not describe — [requesting], between asking and any
/// answer, and [connecting], between accepting the offer and media arriving.
enum ScreenViewStage {
  /// Nothing asked for. The host reports this too, when it has no session.
  idle,

  /// `screen:request` is out and nothing has replied yet.
  requesting,

  /// No desktop app is connected to that machine's bridge, so nobody can answer.
  /// The bridge sends this on the host's behalf precisely because the request
  /// would otherwise be dropped in silence.
  noHost,

  /// The local user on the host machine is being asked to pick a window. Nothing
  /// on this device can hurry that along.
  awaitingConsent,

  /// The host published its window catalog and this device is picking from it.
  /// The mirror of [awaitingConsent]: exactly one of the two ends is choosing,
  /// decided by the `chooser` on the request.
  choosingWindow,

  /// A window is picked; the peer connection is negotiating.
  connecting,

  /// Media is flowing.
  live,

  /// The peer connection lost its path. Frames have stopped, so this must be
  /// visible: the alternative is a still picture the user reads as a working
  /// session and a frozen app.
  interrupted,

  /// The session finished, or never started. [ScreenViewState.reason] is always
  /// populated here — the whole point of this state is that it explains itself.
  ended,

  /// This device cannot receive a screen session at all.
  unsupported,
}

@immutable
class ScreenViewState {
  const ScreenViewState({
    this.stage = ScreenViewStage.idle,
    this.reason,
    this.windowTitle,
    this.frameSize,
    this.controlEnabled = true,
    this.windows = const [],
  });

  final ScreenViewStage stage;

  /// Why the session ended, in words the user can act on.
  final String? reason;
  final String? windowTitle;

  /// The size the host is encoding. Null until the host reports it, which can be
  /// one round trip after the offer — the offer's dimensions are advertised
  /// before the encoder knows them and may be a placeholder.
  final ScreenFrameSize? frameSize;

  /// Whether local gestures and keys are forwarded. Viewing without driving is a
  /// legitimate mode, so this is a viewer-side choice rather than a host policy.
  final bool controlEnabled;

  /// The catalog to pick from, non-empty only in [ScreenViewStage.choosingWindow].
  /// Held rather than passed to a dialog so the list survives a rebuild — the
  /// panel can be reparented mid-choice by a desktop layout toggle.
  final List<ScreenWindowEntry> windows;

  ScreenViewState copyWith({
    ScreenViewStage? stage,
    String? reason,
    bool clearReason = false,
    String? windowTitle,
    ScreenFrameSize? frameSize,
    bool? controlEnabled,
    List<ScreenWindowEntry>? windows,
  }) => ScreenViewState(
    stage: stage ?? this.stage,
    reason: clearReason ? null : (reason ?? this.reason),
    windowTitle: windowTitle ?? this.windowTitle,
    frameSize: frameSize ?? this.frameSize,
    controlEnabled: controlEnabled ?? this.controlEnabled,
    windows: windows ?? this.windows,
  );
}

const String kViewerUnsupportedReason =
    'This device cannot open a desktop window preview.';

const String kViewerLocalSessionReason =
    'This project runs on this machine — its windows are already on screen. '
    'Open it from another device to preview them.';

const String kFingerprintMismatchReason =
    'The host\'s media fingerprint did not match its signed offer, so the '
    'session was refused.';

const String kHostCertificateMismatchReason =
    'The host presented a different certificate than it signed for, so the '
    'session was stopped.';

const String kViewerPeerLostReason = 'The connection to the host dropped.';

const String kViewerInterruptedReason =
    'The connection to the host dropped. Reconnecting...';

const String kViewerHostEndedReason = 'The host ended the session.';

const String kViewerScreenControlOffReason =
    'Screen control was turned off on the host machine.';

const String kViewerRemoteAccessOffReason =
    'Remote access was turned off on the host machine.';

/// The bridge ends a session itself when a machine switch goes off, and says
/// why in a terse token rather than a sentence — it has no UI copy of its own.
/// Keep the keys in lockstep with the `revokeScreenSharing` callers in the
/// bridge's `host-server.ts`; an unmatched token is shown as sent.
const Map<String, String> _bridgeEndReasons = {
  'screen control turned off': kViewerScreenControlOffReason,
  'remote access turned off': kViewerRemoteAccessOffReason,
};

/// Per-project viewer for the native-window preview.
///
/// The mirror of [ScreenShareService]: that one hosts on a LOOPBACK session
/// because the desktop app is the bridge's loopback owner, and this one views on
/// a remote (Iroh peer) session because that is by definition somebody else's
/// machine. Nothing here ever captures or enumerates.
///
/// Signalling is peer-addressed by the bridge in both directions: it stamps
/// every frame sent from here with this peer's lease-authenticated id before
/// handing it to the host alone, and delivers only the host frames addressed to
/// that id. So nothing outbound carries a `viewerId`, nothing inbound needs its
/// `viewerId` checked, and no frame sent from here ever comes back.
///
/// Constructed at [ProjectSession] creation like every other per-project
/// service, subscribing in the constructor so a welcome-replayed `screen:*`
/// frame is not missed.
class ScreenViewService {
  final ProjectSession session;

  ScreenViewService.fromSession(
    this.session, {
    ScreenViewBackend? backend,
    Duration fingerprintProbeInterval = kFingerprintProbeInterval,
  }) : _backend = backend ?? createScreenViewBackend(),
       _fingerprintProbeInterval = fingerprintProbeInterval {
    _statusSub = session.statusStream.listen(_onJson);
  }

  final ScreenViewBackend? _backend;
  final Duration _fingerprintProbeInterval;

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<ScreenIceCandidate>? _candidateSub;
  StreamSubscription<ScreenPeerState>? _peerStateSub;
  StreamSubscription<ScreenFrameSize>? _frameSizeSub;

  final _stateController = StreamController<ScreenViewState>.broadcast();
  ScreenViewState _state = const ScreenViewState();

  ScreenViewPeer? _peer;
  bool _remoteDescriptionSet = false;
  final List<ScreenIceCandidate> _pendingRemoteCandidates = [];
  bool _disposed = false;

  /// The fingerprint the host signed for in its sealed `screen:offer`, held
  /// until the DTLS handshake produces a certificate to check it against.
  String? _hostFingerprint;
  bool _fingerprintVerified = false;
  bool _fingerprintProbeRunning = false;

  Stream<ScreenViewState> get stateStream => _stateController.stream;
  ScreenViewState get currentState => _state;

  String get projectId => session.projectId;

  /// Whether this session can view at all. A loopback session is the HOST side
  /// of this feature — every other transport reaches the machine as an Iroh
  /// peer — and no platform without a backend can render the media.
  bool get canView => !session.transport.isLocal && _backend != null;

  /// The rendered remote video, or null before the first frame. Read at build
  /// time; the widget never owns it.
  Widget? get videoView => _peer?.videoView;

  // --- Local UI surface ---

  /// Asks the host machine for a session. The only way one starts from this side.
  ///
  /// [chooser] decides which end names the window. [ScreenChooser.viewer] is the
  /// order that works when nobody is sitting at the host machine — which is most
  /// of the time, since that is what remote control is for.
  Future<void> requestSession({
    ScreenChooser chooser = ScreenChooser.viewer,
  }) async {
    if (_disposed) return;
    if (!canView) {
      _setState(
        ScreenViewState(
          stage: ScreenViewStage.unsupported,
          reason: session.transport.isLocal
              ? kViewerLocalSessionReason
              : kViewerUnsupportedReason,
        ),
      );
      return;
    }
    await _closePeer();
    _setState(
      ScreenViewState(
        stage: ScreenViewStage.requesting,
        controlEnabled: _state.controlEnabled,
      ),
    );
    _send('screen:request', {
      'projectId': session.projectId,
      'chooser': chooser == ScreenChooser.viewer ? 'viewer' : 'host',
    });
  }

  /// Names one window out of the catalog the host published.
  ///
  /// Silently ignored outside [ScreenViewStage.choosingWindow]: the host only
  /// honours a pick against the catalog it last sent, so a stale one would be
  /// refused there anyway and this keeps the UI from claiming otherwise.
  void pickWindow(String windowId) {
    if (_disposed || _state.stage != ScreenViewStage.choosingWindow) return;
    String? title;
    for (final window in _state.windows) {
      if (window.id == windowId) {
        title = window.title;
        break;
      }
    }
    if (title == null) return;
    _setState(
      ScreenViewState(
        stage: ScreenViewStage.connecting,
        windowTitle: title,
        controlEnabled: _state.controlEnabled,
      ),
    );
    _send('screen:pick', {'windowId': windowId});
  }

  Future<void> stopSession(String reason) async {
    final wasEngaged = _peer != null || _state.stage != ScreenViewStage.idle;
    await _closePeer();
    _setState(ScreenViewState(controlEnabled: _state.controlEnabled));
    if (wasEngaged) _send('screen:stop', {'reason': reason});
  }

  void setControlEnabled(bool enabled) {
    if (_state.controlEnabled == enabled) return;
    _setState(_state.copyWith(controlEnabled: enabled));
  }

  // --- Outbound input ---

  void sendPointer({
    required ViewerPointerAction action,
    required Offset frame,
    String button = 'left',
  }) => _sendInput(
    encodePointerInput(action: action, frame: frame, button: button),
    // Motion is the only stream worth losing: the next sample supersedes it,
    // while a dropped press leaves the target holding a button down.
    reliable: action != ViewerPointerAction.move,
  );

  void sendScroll({
    required Offset frame,
    double deltaX = 0,
    double deltaY = 0,
  }) => _sendInput(
    encodeScrollInput(frame: frame, deltaX: deltaX, deltaY: deltaY),
    reliable: true,
  );

  void sendKey(int virtualKeyCode, {required bool down}) =>
      _sendInput(encodeKeyInput(virtualKeyCode, down: down), reliable: true);

  void sendText(String text) =>
      _sendInput(encodeTextInput(text), reliable: true);

  void _sendInput(String payload, {required bool reliable}) {
    if (!_state.controlEnabled || _state.stage != ScreenViewStage.live) return;
    _peer?.sendInput(payload, reliable: reliable);
  }

  // --- Inbound ---

  void _onJson(Map<String, dynamic> json) {
    if (!canView) return;
    final parsed = parseAbMessage(json);
    switch (parsed) {
      case ScreenWindowsMessage():
        _handleWindows(parsed);
      case ScreenStateMessage():
        _handleState(parsed);
      case ScreenOfferMessage():
        unawaited(_handleOffer(parsed));
      case ScreenIceMessage():
        unawaited(_handleRemoteIce(parsed));
      case ScreenStopMessage():
        unawaited(_handleRemoteStop(parsed));
    }
  }

  /// The host's answer to a viewer-chooses request.
  ///
  /// Refused once a session is under way: a catalog arriving mid-stream would
  /// otherwise throw away a working picture to show a list nobody asked for.
  void _handleWindows(ScreenWindowsMessage msg) {
    switch (_state.stage) {
      case ScreenViewStage.requesting:
      case ScreenViewStage.choosingWindow:
        _setState(
          ScreenViewState(
            stage: ScreenViewStage.choosingWindow,
            controlEnabled: _state.controlEnabled,
            windows: msg.windows,
          ),
        );
      case _:
        return;
    }
  }

  void _handleState(ScreenStateMessage msg) {
    final size = (msg.width != null && msg.height != null)
        ? ScreenFrameSize(msg.width!, msg.height!)
        : null;
    switch (msg.status) {
      // This and `ended` can land mid-session — the host app quit, or a machine
      // switch went off — and the peer is torn down on the spot: ICE would
      // otherwise keep the last frame on screen for tens of seconds before
      // admitting the path is gone.
      case ScreenSessionStatus.noHost:
        unawaited(_end(ScreenViewStage.noHost, msg.reason));
      case ScreenSessionStatus.awaitingConsent:
        _setState(
          ScreenViewState(
            stage: ScreenViewStage.awaitingConsent,
            controlEnabled: _state.controlEnabled,
          ),
        );
      case ScreenSessionStatus.live:
        // Never a promotion to live on its own: the host publishes this the
        // moment it has an offer, which is before any media has arrived. The
        // peer's own `connected` is what proves the picture exists — except
        // after an interruption, where this is the host telling us the path it
        // lost has come back.
        _setState(
          _state.copyWith(
            stage:
                _state.stage == ScreenViewStage.live ||
                    _state.stage == ScreenViewStage.interrupted
                ? ScreenViewStage.live
                : ScreenViewStage.connecting,
            windowTitle: msg.windowTitle,
            frameSize: size,
            clearReason: true,
          ),
        );
      case ScreenSessionStatus.interrupted:
        // The host noticed the path drop before our own peer did, or instead of
        // it. Either way the picture on screen is stale from here on.
        _setState(
          _state.copyWith(
            stage: ScreenViewStage.interrupted,
            reason: msg.reason ?? kViewerInterruptedReason,
          ),
        );
      case ScreenSessionStatus.ended:
        final reason = msg.reason;
        unawaited(
          _end(
            ScreenViewStage.ended,
            reason == null
                ? kViewerHostEndedReason
                : (_bridgeEndReasons[reason] ?? reason),
          ),
        );
      case ScreenSessionStatus.idle:
        unawaited(_end(ScreenViewStage.idle, null));
    }
  }

  Future<void> _handleOffer(ScreenOfferMessage msg) async {
    final backend = _backend;
    if (backend == null || _disposed) return;
    // The sealed channel carries the fingerprint the host claims; the SDP
    // carries the one it will present in the DTLS handshake. This is the viewer
    // half of the binding that shuts out a MITM on the signalling path — the
    // host runs the same check on the answer, and neither half is sufficient
    // alone.
    final negotiated = parseDtlsFingerprint(msg.sdp);
    if (negotiated == null ||
        !dtlsFingerprintsMatch(negotiated, msg.dtlsFingerprint)) {
      await _closePeer();
      _setState(
        ScreenViewState(
          stage: ScreenViewStage.ended,
          reason: kFingerprintMismatchReason,
          controlEnabled: _state.controlEnabled,
        ),
      );
      _send('screen:stop', {'reason': kFingerprintMismatchReason});
      return;
    }

    // Candidates the host trickled ahead of this offer are buffered already, and
    // the peer swap below clears that buffer — so carry them across.
    final buffered = List<ScreenIceCandidate>.of(_pendingRemoteCandidates);
    await _closePeer();
    _pendingRemoteCandidates.addAll(buffered);
    final ScreenViewPeer peer;
    try {
      peer = await backend.createPeer();
    } catch (err) {
      await _end(
        ScreenViewStage.ended,
        'Could not open the video session: $err',
      );
      return;
    }
    if (_disposed) {
      await peer.dispose();
      return;
    }
    _peer = peer;
    _candidateSub = peer.localCandidates.listen(_onLocalCandidate);
    _peerStateSub = peer.peerStates.listen(_onPeerState);
    _frameSizeSub = peer.frameSizes.listen(_onFrameSize);

    final ScreenSdp answer;
    try {
      answer = await peer.answerOffer(msg.sdp);
    } catch (err) {
      await _end(ScreenViewStage.ended, 'Could not answer the host: $err');
      return;
    }
    _remoteDescriptionSet = true;
    _hostFingerprint = msg.dtlsFingerprint;

    final offered = ScreenFrameSize(msg.width, msg.height);
    _setState(
      ScreenViewState(
        stage: ScreenViewStage.connecting,
        windowTitle: _state.windowTitle,
        // A collapsed offer size is the host advertising before its encoder knew
        // the dimensions, not a 1x1 window — sizing from it would letterbox the
        // first paint into a single pixel.
        frameSize: offered.isCollapsed ? _state.frameSize : offered,
        controlEnabled: _state.controlEnabled,
      ),
    );
    _send('screen:answer', {
      'sdp': answer.sdp,
      'dtlsFingerprint': answer.dtlsFingerprint,
    });

    // Drain into a copy: more candidates can arrive across the awaits below, and
    // iterating the live list while it grows throws.
    final flush = List<ScreenIceCandidate>.of(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in flush) {
      await _addRemoteCandidate(peer, candidate);
    }
  }

  Future<void> _handleRemoteIce(ScreenIceMessage msg) async {
    final candidate = ScreenIceCandidate(
      candidate: msg.candidate,
      sdpMid: msg.sdpMid,
      sdpMLineIndex: msg.sdpMLineIndex,
    );
    final peer = _peer;
    // libwebrtc rejects a candidate until a remote description exists, and the
    // host starts trickling the moment it has an offer — well before our answer.
    if (peer == null || !_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await _addRemoteCandidate(peer, candidate);
  }

  Future<void> _addRemoteCandidate(
    ScreenViewPeer peer,
    ScreenIceCandidate candidate,
  ) async {
    try {
      await peer.addRemoteCandidate(candidate);
    } catch (err) {
      developer.log(
        'screen view: rejected remote candidate: $err',
        name: 'antgrid.screen',
      );
    }
  }

  Future<void> _handleRemoteStop(ScreenStopMessage msg) =>
      _end(ScreenViewStage.ended, msg.reason);

  // --- Peer lifecycle ---

  void _onLocalCandidate(ScreenIceCandidate candidate) {
    _send('screen:ice', {
      'candidate': candidate.candidate,
      if (candidate.sdpMid != null) 'sdpMid': candidate.sdpMid,
      if (candidate.sdpMLineIndex != null)
        'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  void _onPeerState(ScreenPeerState state) {
    switch (state) {
      case ScreenPeerState.connected:
        _setState(
          _state.copyWith(stage: ScreenViewStage.live, clearReason: true),
        );
        unawaited(_verifyNegotiatedFingerprint());
      case ScreenPeerState.disconnected:
        // ICE recovers from this on its own after a network change, so it does
        // not end the session — but the video is frozen from here, and a still
        // picture presented as live is the failure this state exists to avoid.
        if (_state.stage != ScreenViewStage.live) return;
        _setState(
          _state.copyWith(
            stage: ScreenViewStage.interrupted,
            reason: kViewerInterruptedReason,
          ),
        );
      case ScreenPeerState.failed:
      case ScreenPeerState.closed:
        unawaited(_end(ScreenViewStage.ended, kViewerPeerLostReason));
      case ScreenPeerState.connecting:
        break;
    }
  }

  /// The mirror of the host's check: the sealed `screen:offer` said which
  /// certificate the host would present, and this is where that claim is held
  /// against the one DTLS actually accepted. Both halves are needed — anything
  /// on the signalling path that can rewrite the SDP is only shut out when each
  /// end verifies the other.
  Future<void> _verifyNegotiatedFingerprint() async {
    final peer = _peer;
    final claimed = _hostFingerprint;
    if (peer == null ||
        claimed == null ||
        _fingerprintVerified ||
        _fingerprintProbeRunning) {
      return;
    }
    _fingerprintProbeRunning = true;
    try {
      for (var attempt = 0; attempt < kFingerprintProbeAttempts; attempt++) {
        if (_disposed || !identical(_peer, peer)) return;
        final negotiated = await peer.remoteFingerprint();
        if (negotiated != null) {
          if (dtlsFingerprintDigestsMatch(negotiated, claimed)) {
            _fingerprintVerified = true;
          } else {
            await _end(ScreenViewStage.ended, kHostCertificateMismatchReason);
            _send('screen:stop', {'reason': kHostCertificateMismatchReason});
          }
          return;
        }
        await Future<void>.delayed(_fingerprintProbeInterval);
      }
      // Fails open for the same reason the host's does: DTLS already refuses a
      // certificate the remote description did not name, and that description
      // was checked against the sealed offer, so an unreadable statistic costs
      // the confirmation rather than the binding.
      developer.log(
        'screen view: no remote certificate reported, media binding '
        'unconfirmed',
        name: 'antgrid.screen',
      );
    } finally {
      _fingerprintProbeRunning = false;
    }
  }

  void _onFrameSize(ScreenFrameSize size) {
    if (size.isCollapsed || size == _state.frameSize) return;
    _setState(_state.copyWith(frameSize: size));
  }

  Future<void> _end(ScreenViewStage stage, String? reason) async {
    await _closePeer();
    _setState(
      ScreenViewState(
        stage: stage,
        reason: reason,
        windowTitle: _state.windowTitle,
        controlEnabled: _state.controlEnabled,
      ),
    );
  }

  Future<void> _closePeer() async {
    final peer = _peer;
    _peer = null;
    _remoteDescriptionSet = false;
    _hostFingerprint = null;
    _fingerprintVerified = false;
    _pendingRemoteCandidates.clear();
    final subs = [_candidateSub, _peerStateSub, _frameSizeSub];
    _candidateSub = null;
    _peerStateSub = null;
    _frameSizeSub = null;
    for (final sub in subs) {
      await sub?.cancel();
    }
    await peer?.dispose();
  }

  // --- Outbound ---

  void _send(String type, Map<String, dynamic> payload) {
    if (_disposed) return;
    unawaited(session.send(createAbMessage(type, payload)));
  }

  void _setState(ScreenViewState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await _closePeer();
    _disposed = true;
    await _statusSub?.cancel();
    _statusSub = null;
    await _stateController.close();
  }
}
