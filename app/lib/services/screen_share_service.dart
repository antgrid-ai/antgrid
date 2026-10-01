import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../models/ab_message.dart';
import '../models/screen_models.dart';
import '../native/input_injector.dart';
import '../native/win32_input.dart';
import '../project/project_session.dart';
import 'screen_share_backend.dart';
import 'webrtc_screen_backend.dart';

/// Where a hosted screen session is in its life. Narrower than the wire's
/// [ScreenSessionStatus] on purpose — the host does not need `no-host`, which
/// the bridge answers on its behalf, and it does need to distinguish "picked a
/// window, still negotiating" from "media flowing".
enum ScreenShareStage {
  /// Nothing asked for, nothing running.
  idle,

  /// A remote viewer asked. The LOCAL user must pick a window; the request never
  /// names one.
  awaitingConsent,

  /// A remote viewer asked and is picking from the catalog this machine
  /// published. Separate from [awaitingConsent] because the local picker must
  /// NOT open: two dialogs racing for one session would let the machine and the
  /// viewer pick different windows.
  awaitingPick,

  /// A window is picked and negotiation is in flight.
  starting,

  /// Capture is running and the offer is out. Whether anyone is actually
  /// WATCHING is [ScreenShareState.viewerConnected], not this: the host reaches
  /// this stage the moment it has an offer, which is well before — and possibly
  /// instead of — a viewer ever answering.
  live,

  /// The peer connection lost its path. Still a session — ICE recovers from an
  /// ordinary network change on its own — but no frames are reaching the viewer,
  /// and both ends have to say so rather than sit on the last frame.
  interrupted,

  /// The last session ended on something the user has to be told about.
  failed,
}

@immutable
class ScreenShareState {
  const ScreenShareState({
    this.stage = ScreenShareStage.idle,
    this.reason,
    this.windowTitle,
    this.frameSize,
    this.inputActive = false,
    this.viewerConnected = false,
  });

  final ScreenShareStage stage;

  /// Plain-language explanation for [ScreenShareStage.failed], or the reason
  /// input is unavailable while [stage] is live and [inputActive] is false.
  final String? reason;
  final String? windowTitle;
  final ScreenFrameSize? frameSize;

  /// Whether remote input is actually reaching the target. False during a live
  /// session means the picture works but control does not — an elevated target,
  /// or the OS refused the foreground.
  final bool inputActive;

  /// Whether a viewer's peer connection has ever come up on this session.
  ///
  /// The host is [ScreenShareStage.live] from the moment it has an offer, which
  /// says nothing about anyone answering it — a session the user armed with no
  /// device connected sits there indefinitely, capturing and transmitting
  /// nothing. Without this the UI cannot tell that apart from a viewer that is
  /// connected but not yet rendering, and the two need opposite words.
  ///
  /// Stays true across [ScreenShareStage.interrupted]: a path that dropped is a
  /// viewer that exists and is expected back, not the never-connected case.
  final bool viewerConnected;

  ScreenShareState copyWith({
    ScreenShareStage? stage,
    String? reason,
    bool clearReason = false,
    String? windowTitle,
    ScreenFrameSize? frameSize,
    bool? inputActive,
    bool? viewerConnected,
  }) => ScreenShareState(
    stage: stage ?? this.stage,
    reason: clearReason ? null : (reason ?? this.reason),
    windowTitle: windowTitle ?? this.windowTitle,
    frameSize: frameSize ?? this.frameSize,
    inputActive: inputActive ?? this.inputActive,
    viewerConnected: viewerConnected ?? this.viewerConnected,
  );
}

/// The machine's screen-control switch as the capture host sees it.
///
/// Per-frame gating cannot enforce this: remote input rides a WebRTC datachannel
/// that never reaches the bridge, so the only thing that actually cuts a remote
/// peer off is tearing the peer connection down. That makes [changes] the kill
/// switch rather than a courtesy over one.
abstract class ScreenControlPolicy {
  bool get enabled;
  Stream<bool> get changes;
}

/// Screen-space origin of the target window, used to build the frame→screen
/// transform. Injected so the state machine never reaches `dart:ffi` directly.
typedef WindowOriginProbe = ScreenPoint? Function(int windowId);

ScreenPoint? defaultWindowOrigin(int windowId) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
  final rect = windowScreenRect(windowId);
  return rect == null ? null : ScreenPoint(rect.left, rect.top);
}

/// Makes the target capturable before a capture is attempted, reporting whether
/// it now is. Injected for the same reason as [WindowOriginProbe].
typedef WindowCapturePrep = Future<bool> Function(int windowId);

/// Brings the target to the foreground, restoring it first if it is minimised.
///
/// This is a PRECONDITION of capture, not a convenience, and it applies to EVERY
/// window rather than only minimised ones. `RTCDesktopCapturer::Start()` fails a
/// window source unless BOTH `SelectSource` (which refuses an iconic window) and
/// `FocusOnSelectedSource` succeed, and the latter is
/// `BringWindowToTop && SetForegroundWindow` — which Windows denies to a process
/// that does not already hold foreground rights. A host being driven from a
/// phone never holds them. flutter_webrtc discards that failed return value and
/// hands back a track anyway, so the session negotiates, ICE succeeds, and no
/// frame ever arrives.
///
/// Raising first is what makes libwebrtc's own `SetForegroundWindow` succeed: on
/// a window that is already frontmost it has nothing to do. Before this, only a
/// window the local user happened to be touching satisfied that by accident.
///
/// The raise inside `beginSession` cannot serve this: it runs from
/// [_beginInput], which is gated on a frame size that only a working capture can
/// produce. That ordering is why remote control could never fix its own
/// precondition.
Future<bool> defaultPrepareWindowForCapture(int windowId) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return true;
  return focusWindowForCapture(windowId);
}

/// How often a live session re-reads the encoder's frame size. The only thing
/// this catches is a window being minimised mid-capture, which is not an event
/// libwebrtc reports — the stream simply collapses to one pixel.
const Duration kScreenFrameHealthInterval = Duration(seconds: 2);

/// How long a peer connection may stay disconnected before the session is ended.
/// Long enough to cover a Wi-Fi handover or a cellular hop, short enough that a
/// path which is never coming back does not leave the target window held in the
/// foreground indefinitely.
const Duration kScreenPeerRecoveryGrace = Duration(seconds: 20);

/// How many consecutive frame-health polls may find no encoded frame, once a
/// viewer is connected, before the session is given up as dead. Six polls is
/// twelve seconds — long enough to cover a slow first capture on a busy machine,
/// short enough that nobody watches a spinner wondering whether to wait.
const int kMaxFramelessPolls = 6;

const String kMinimisedReason =
    'That window was minimised. A minimised window cannot be captured — '
    'ask again to bring it back.';

/// The target would not come to the front, so libwebrtc will refuse to capture
/// it. Covers both a minimised window that would not restore and a live one the
/// OS would not let this process raise (a target running elevated, typically).
///
/// Named separately from [kNoFramesReason] because it is knowable BEFORE any
/// capture is attempted, and waiting twelve seconds to say so would be a worse
/// answer to the same question.
const String kCouldNotFocusReason =
    'That window would not come to the front on that machine, so it cannot be '
    'captured. Click it there and ask again.';

/// The capture started, the peer connected, and no frame ever arrived.
///
/// Windows reports this failure only by silence: `RTCDesktopCapturer::Start()`
/// can return `CS_FAILED` and the plugin discards that, handing back a track
/// attached to a capturer that never ran. Without this the viewer waits on a
/// first frame that is never coming.
const String kNoFramesReason =
    'That window never produced a picture. It may have been minimised or closed '
    'as the session started — ask again, or pick a different window.';

const String kPolicyRevokedReason =
    'Screen control was turned off on this machine.';

const String kRemoteAccessRevokedReason =
    'Remote access was turned off on this machine.';

/// Sent to the viewer as-is, so it is phrased from that side.
const String kConsentDeclinedReason =
    'The request was declined on that machine.';

/// The bridge ends a capture itself when a machine switch goes off, naming the
/// switch in a terse token. Keep the keys in lockstep with the
/// `revokeScreenSharing` callers in the bridge's `host-server.ts`; an unmatched
/// token is shown as sent.
const Map<String, String> _bridgeRevocationReasons = {
  'screen control turned off': kPolicyRevokedReason,
  'remote access turned off': kRemoteAccessRevokedReason,
};

const String kNoPolicyReason =
    'Screen control is unavailable: this build cannot see the machine switch.';

/// Distinct from [kNoPolicyReason] because the remedies are opposite: this one
/// names a setting the user owns and can act on, and telling them the build is
/// broken instead would send them looking for a bug that isn't there.
const String kPolicyDisabledReason =
    'Screen control is turned off on this machine. Turn it on under Remote '
    'access to share a window.';

const String kNoWindowsReason = 'That machine has no shareable window open.';

/// A pick that names a window the host never published. Says nothing about which
/// windows exist — an answer that distinguished "closed since" from "never
/// offered" would leak the catalog it exists to bound.
const String kUnknownWindowReason =
    'That window is no longer available. Ask again for the current list.';

/// One capture has one viewer. A second device asking mid-session is refused
/// rather than adopted, because adopting it would hand it a peer connection
/// negotiated for someone else.
const String kHostBusyReason =
    'That machine is already sharing a window with another device.';

const String kUnsupportedPlatformReason =
    'This machine cannot share a window: screen sharing is Windows-only today.';

const String kAnswerFingerprintMismatchReason =
    'The viewer\'s media fingerprint did not match its signed answer.';

const String kViewerCertificateMismatchReason =
    'The viewer presented a different certificate than it signed for, so the '
    'session was stopped.';

const String kPeerInterruptedReason =
    'The connection to the viewer dropped. Reconnecting...';

const String kPeerRecoveryTimedOutReason =
    'The connection to the viewer did not come back.';

const String kPeerLostReason = 'The connection to the viewer dropped.';

/// Input cannot be aimed before the frame's dimensions are known, and on Windows
/// the track publishes none — only the encoder's `outbound-rtp` stats do, which
/// is one poll away. Distinct from [kWindowOffScreenReason] because this one
/// resolves itself and that one does not.
const String kAwaitingFrameSizeReason =
    'Waiting for the first frame before remote control starts...';

const String kWindowOffScreenReason = 'Could not locate that window on screen.';

/// The OS refused to bring the target back to the front, so the press that asked
/// for it went nowhere.
///
/// Recoverable by definition — the next press tries again — so this is a warning
/// on a live session rather than an end to it.
const String kForegroundRaiseDeniedReason =
    'Windows would not bring that window to the front, so your input did not '
    'reach it.';

/// Per-project host for the native-window preview.
///
/// Constructed at [ProjectSession] creation like every other per-project
/// service, subscribing in the constructor so a welcome-replayed `screen:*`
/// frame is not missed. Only a LOOPBACK session takes the host role: the desktop
/// app is the bridge's loopback owner, and a relay-mode session is the viewer
/// side of some other machine's screen, which must never start a capture here.
///
/// Two things about this transport are easy to get wrong:
///
///  * **Every frame is addressed to one viewer.** The bridge stamps each
///    inbound `screen:*` with the Iroh peer id its sender was admitted under,
///    and delivers an outbound one only to the peer its `viewerId` names,
///    dropping one that names nobody. So a session belongs to the viewer whose
///    `screen:request` opened it ([_viewerId]): everything sent carries that
///    id, and a frame from any other viewer is ignored rather than allowed to
///    steer a capture it never asked for.
///  * **The bridge's own stop names no viewer.** Every viewer frame arrives
///    stamped, so an unaddressed `screen:stop` can only be the bridge revoking
///    screen sharing, and it ends whatever is running — including a session
///    whose viewer the bridge lost track of when this app's socket last dropped.
///  * **Signalling is status-tier.** It must not ride the heavy stream, which is
///    focus-gated: a session would stall the moment the user looked at another
///    panel.
class ScreenShareService {
  final ProjectSession session;

  ScreenShareService.fromSession(
    this.session, {
    ScreenControlPolicy? policy,
    ScreenShareBackend? backend,
    InputInjector? injector,
    WindowOriginProbe windowOrigin = defaultWindowOrigin,
    WindowCapturePrep prepareWindow = defaultPrepareWindowForCapture,
    Duration frameHealthInterval = kScreenFrameHealthInterval,
    Duration peerRecoveryGrace = kScreenPeerRecoveryGrace,
    Duration fingerprintProbeInterval = kFingerprintProbeInterval,
  }) : _policy = policy,
       _backend = backend ?? createScreenShareBackend(),
       _injector = injector ?? createInputInjector(),
       _windowOrigin = windowOrigin,
       _prepareWindow = prepareWindow,
       _frameHealthInterval = frameHealthInterval,
       _peerRecoveryGrace = peerRecoveryGrace,
       _fingerprintProbeInterval = fingerprintProbeInterval {
    _statusSub = session.statusStream.listen(_onJson);
    _policySub = policy?.changes.listen((enabled) {
      if (!enabled) unawaited(_teardown(kPolicyRevokedReason, failed: true));
    });
  }

  final ScreenControlPolicy? _policy;
  final ScreenShareBackend? _backend;
  final InputInjector? _injector;
  final WindowOriginProbe _windowOrigin;
  final WindowCapturePrep _prepareWindow;
  final Duration _frameHealthInterval;
  final Duration _peerRecoveryGrace;
  final Duration _fingerprintProbeInterval;

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<bool>? _policySub;
  StreamSubscription<ScreenIceCandidate>? _candidateSub;
  StreamSubscription<ScreenPeerState>? _peerStateSub;
  StreamSubscription<String>? _inputSub;
  StreamSubscription<void>? _captureEndedSub;
  Timer? _frameHealthTimer;
  Timer? _recoveryTimer;

  final _stateController = StreamController<ScreenShareState>.broadcast();
  ScreenShareState _state = const ScreenShareState();

  ScreenSharePeer? _peer;
  int? _targetWindowId;
  bool _answered = false;

  /// The fingerprint the viewer signed for in its sealed `screen:answer`, held
  /// until the DTLS handshake produces a certificate to check it against.
  String? _viewerFingerprint;
  bool _fingerprintVerified = false;
  bool _fingerprintProbeRunning = false;
  final List<ScreenIceCandidate> _pendingRemoteCandidates = [];
  bool _disposed = false;

  /// Bumped by every [_teardown]. [startSession] awaits several times before it
  /// has a peer to tear down, so a stop landing in between can only reach it
  /// through this: without it the start would resume and go live for nobody,
  /// ready for whichever device asked next to adopt.
  int _generation = 0;

  /// The viewer this session belongs to: the peer id the bridge stamped on the
  /// `screen:request` that opened it. Null while nothing is pending, and for a
  /// session the local user armed before any device asked — which the first
  /// request then adopts.
  String? _viewerId;

  /// Offer and candidates produced while no viewer was bound. The bridge drops
  /// an unaddressed frame, so without these a viewer adopting an armed session
  /// would be told it is live and never receive anything to connect with.
  final List<(String, Map<String, dynamic>)> _unaddressed = [];

  Stream<ScreenShareState> get stateStream => _stateController.stream;
  ScreenShareState get currentState => _state;

  String get projectId => session.projectId;

  /// Whether this session can host at all. False on a viewer (relay) session and
  /// on any platform without a capture backend.
  bool get canHost => session.transport.isLocal && _backend != null;

  /// Late-arriving thumbnails and titles for windows already enumerated.
  Stream<ScreenWindow> get windowUpdates =>
      _backend?.windowUpdates ?? const Stream<ScreenWindow>.empty();

  // --- Inbound ---

  void _onJson(Map<String, dynamic> json) {
    final parsed = parseAbMessage(json);
    final viewerId = switch (parsed) {
      ScreenRequestMessage(:final viewerId) ||
      ScreenPickMessage(:final viewerId) ||
      ScreenAnswerMessage(:final viewerId) ||
      ScreenIceMessage(:final viewerId) ||
      ScreenStopMessage(:final viewerId) => viewerId,
      _ => null,
    };
    // The bridge stamps every frame a viewer sends, so one without a viewer id
    // has nobody behind it to answer — except the bridge's own stop.
    if (viewerId == null) {
      if (parsed is ScreenStopMessage) unawaited(_handleRevocation(parsed));
      return;
    }
    if (parsed is ScreenRequestMessage) {
      _handleRequest(parsed, viewerId);
      return;
    }
    if (viewerId != _viewerId) return;
    switch (parsed) {
      case ScreenPickMessage():
        unawaited(_handlePick(parsed));
      case ScreenAnswerMessage():
        unawaited(_handleAnswer(parsed));
      case ScreenIceMessage():
        unawaited(_handleRemoteIce(parsed));
      case ScreenStopMessage():
        unawaited(_handleRemoteStop(parsed));
    }
  }

  void _handleRequest(ScreenRequestMessage msg, String viewerId) {
    if (!canHost) {
      // A viewer session must stay silent rather than answer for a machine it is
      // not hosting; only a loopback host that genuinely cannot capture replies.
      if (session.transport.isLocal) {
        _sendState(
          ScreenSessionStatus.ended,
          reason: kUnsupportedPlatformReason,
          to: viewerId,
        );
      }
      return;
    }
    if (_policy == null) {
      _sendState(
        ScreenSessionStatus.ended,
        reason: kNoPolicyReason,
        to: viewerId,
      );
      return;
    }
    // The bridge already dropped this frame if the switch was off, but it is
    // read again here because the two checks race: the switch can flip between
    // the relay hop and the local user picking a window.
    if (!_policy.enabled) {
      _sendState(
        ScreenSessionStatus.ended,
        reason: kPolicyRevokedReason,
        to: viewerId,
      );
      return;
    }
    final bound = _viewerId;
    if (bound != null && bound != viewerId) {
      _sendState(
        ScreenSessionStatus.ended,
        reason: kHostBusyReason,
        to: viewerId,
      );
      return;
    }
    final stage = _state.stage;
    if (stage == ScreenShareStage.starting ||
        stage == ScreenShareStage.live ||
        stage == ScreenShareStage.interrupted) {
      if (bound == viewerId) {
        // The viewer drops its peer before every request, so the session it
        // had is unreachable from its side: re-advertising it would leave the
        // viewer waiting on an offer that never comes.
        unawaited(_restartFor(msg, viewerId));
        return;
      }
      // A session the local user armed before any device asked.
      _viewerId = viewerId;
      final held = List.of(_unaddressed);
      _unaddressed.clear();
      for (final (type, payload) in held) {
        _send(type, payload);
      }
      // The offer is still being made, and goes to the bound viewer when it is.
      if (stage == ScreenShareStage.starting) return;
      final live = stage == ScreenShareStage.live;
      _sendState(
        live ? ScreenSessionStatus.live : ScreenSessionStatus.interrupted,
        reason: live ? null : kPeerInterruptedReason,
        windowTitle: _state.windowTitle,
        size: _state.frameSize,
      );
      return;
    }
    _openRequest(msg, viewerId);
  }

  void _openRequest(ScreenRequestMessage msg, String viewerId) {
    _viewerId = viewerId;
    if (msg.chooser == ScreenChooser.viewer) {
      unawaited(_publishWindows());
      return;
    }
    _setState(const ScreenShareState(stage: ScreenShareStage.awaitingConsent));
    _sendState(ScreenSessionStatus.awaitingConsent);
  }

  /// Ends [viewerId]'s current session and handles its new request afresh. The
  /// viewer stays bound throughout, so no other device can take the session
  /// over in between.
  Future<void> _restartFor(ScreenRequestMessage msg, String viewerId) async {
    await _teardown(
      'Replaced by a new request',
      notifyPeer: false,
      keepViewer: true,
    );
    // A stop from the viewer can land during the teardown and unbind it.
    if (_disposed || _viewerId != viewerId) return;
    _openRequest(msg, viewerId);
  }

  /// Answers a viewer-chooses request with the catalog it picks from.
  ///
  /// The catalog is remembered because it is the ONLY thing bounding which
  /// window a remote pick may name — the same shape as the host's project
  /// catalog, and with nothing behind it either.
  Future<void> _publishWindows() async {
    final backend = _backend;
    if (backend == null) return;
    final viewerId = _viewerId;
    final List<ScreenWindow> windows;
    // The viewer can leave, or a stop can free the session for another, while
    // the enumeration runs; either way neither this catalog nor its failure has
    // a recipient any more.
    try {
      windows = await backend.listWindows();
    } catch (err) {
      if (_viewerId == viewerId) {
        _refuse('Could not list the windows on this machine: $err');
      }
      return;
    }
    if (_viewerId != viewerId) return;
    // The switch can go off across the enumeration, and a catalog is a
    // disclosure in its own right — so it is re-checked here rather than only
    // at the capture that may follow.
    if (_disposed || !(_policy?.enabled ?? false)) {
      _refuse(kPolicyRevokedReason);
      return;
    }
    if (windows.isEmpty) {
      _refuse(kNoWindowsReason);
      return;
    }
    _offeredWindowIds
      ..clear()
      ..addAll(windows.map((w) => w.id));
    _setState(const ScreenShareState(stage: ScreenShareStage.awaitingPick));
    _send('screen:windows', {
      'windows': [
        for (final w in windows)
          {
            'id': w.id,
            'title': w.title.isEmpty ? 'Untitled window' : w.title,
            if (w.minimised) 'minimised': true,
          },
      ],
    });
  }

  /// Window ids this host published to a viewer, and therefore the only ones a
  /// remote pick may name.
  final Set<String> _offeredWindowIds = <String>{};

  Future<void> _handlePick(ScreenPickMessage msg) async {
    if (!canHost) return;
    if (!_offeredWindowIds.contains(msg.windowId)) {
      // Either a stale catalog or a window named out of thin air. The two are
      // indistinguishable from here and the answer is the same for both.
      _offeredWindowIds.clear();
      _setState(const ScreenShareState());
      _refuse(kUnknownWindowReason);
      return;
    }
    _offeredWindowIds.clear();
    await startSession(msg.windowId);
  }

  Future<void> _handleAnswer(ScreenAnswerMessage msg) async {
    final peer = _peer;
    if (peer == null) return;
    // The sealed channel carries the fingerprint the viewer claims; the SDP
    // carries the one it will actually present in the DTLS handshake. Binding
    // the two is what keeps anything on the signalling path from inserting
    // itself into the media, so a mismatch aborts rather than warns.
    final offered = parseDtlsFingerprint(msg.sdp);
    if (offered == null ||
        !dtlsFingerprintsMatch(offered, msg.dtlsFingerprint)) {
      await _teardown(kAnswerFingerprintMismatchReason, failed: true);
      return;
    }
    try {
      await peer.acceptAnswer(msg.sdp);
    } catch (err) {
      await _teardown('Could not complete the connection: $err', failed: true);
      return;
    }
    _answered = true;
    _viewerFingerprint = msg.dtlsFingerprint;
    for (final candidate in _pendingRemoteCandidates) {
      await _addRemoteCandidate(peer, candidate);
    }
    _pendingRemoteCandidates.clear();
    // The peer can already be connected when the answer is only now being
    // applied here, in which case no further state transition would arrive to
    // trigger the check.
    unawaited(_verifyNegotiatedFingerprint());
  }

  /// Confirms the media path is the one the sealed channel negotiated.
  ///
  /// The SDP check above proves the viewer's sealed claim agrees with the SDP it
  /// sent. This proves the certificate the DTLS handshake actually accepted is
  /// that same one — which is what leaves anything able to rewrite the
  /// signalling unable to insert itself into the media.
  Future<void> _verifyNegotiatedFingerprint() async {
    final peer = _peer;
    final claimed = _viewerFingerprint;
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
            await _teardown(kViewerCertificateMismatchReason, failed: true);
          }
          return;
        }
        await Future<void>.delayed(_fingerprintProbeInterval);
      }
      // Deliberately fails open, and only here: DTLS itself refuses any
      // certificate the remote description did not name, and that description
      // was checked against the sealed claim — so an unreadable statistic costs
      // the confirmation, not the binding. Ending sessions over a field some
      // platform does not populate would be the larger harm.
      developer.log(
        'screen share: no remote certificate reported, media binding '
        'unconfirmed',
        name: 'antgrid.screen',
      );
    } finally {
      _fingerprintProbeRunning = false;
    }
  }

  Future<void> _handleRemoteIce(ScreenIceMessage msg) async {
    final peer = _peer;
    if (peer == null) return;
    final candidate = ScreenIceCandidate(
      candidate: msg.candidate,
      sdpMid: msg.sdpMid,
      sdpMLineIndex: msg.sdpMLineIndex,
    );
    // A candidate that arrives before the answer has nowhere to go — libwebrtc
    // rejects it until a remote description exists.
    if (!_answered) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await _addRemoteCandidate(peer, candidate);
  }

  Future<void> _addRemoteCandidate(
    ScreenSharePeer peer,
    ScreenIceCandidate candidate,
  ) async {
    try {
      await peer.addRemoteCandidate(candidate);
    } catch (err) {
      developer.log(
        'screen share: rejected remote candidate: $err',
        name: 'antgrid.screen',
      );
    }
  }

  /// A stop from the viewer, or from the bridge on its behalf as `viewer-gone`
  /// when its connection closed. Neither needs an answer: the viewer ended it,
  /// or is gone.
  Future<void> _handleRemoteStop(ScreenStopMessage msg) =>
      _teardown(msg.reason, notifyPeer: false);

  /// The bridge revoked screen sharing because a machine switch went off. A
  /// failure rather than a quiet return to idle, because for remote access this
  /// is the only word the host gets — nothing here watches that switch — and a
  /// share that simply vanishes reads as a bug. The bridge has already told
  /// every viewer it knows about.
  Future<void> _handleRevocation(ScreenStopMessage msg) => _teardown(
    _bridgeRevocationReasons[msg.reason] ?? msg.reason,
    failed: true,
    notifyPeer: false,
  );

  // --- Local UI surface ---

  /// The windows the local user may pick from. Thumbnails are absent here and
  /// arrive later on [windowUpdates]; reading them synchronously always yields
  /// nothing.
  Future<List<ScreenWindow>> listWindows() async {
    final backend = _backend;
    if (backend == null) return const [];
    return backend.listWindows();
  }

  /// The local user picked [windowId]. This is the only way a session starts —
  /// no remote message names a window.
  Future<void> startSession(String windowId) async {
    final backend = _backend;
    if (_disposed || backend == null) return;
    if (_policy == null || !_policy.enabled) {
      final reason = _policy == null ? kNoPolicyReason : kPolicyDisabledReason;
      _setFailed(reason);
      _refuse(reason);
      return;
    }
    if (_peer != null) {
      await _teardown('Replaced by a new session', keepViewer: true);
    }

    _setState(const ScreenShareState(stage: ScreenShareStage.starting));
    final generation = _generation;
    bool cancelled() => _disposed || generation != _generation;

    // Before the capture, not after: libwebrtc demands the target be frontmost
    // and reports the refusal by producing nothing rather than by failing. It is
    // also the honest reading of the request — a remote peer asked to watch this
    // window, which it cannot do while something else covers it.
    final targetWindow = int.tryParse(windowId);
    if (targetWindow != null) {
      final focused = await _prepareWindow(targetWindow);
      if (cancelled()) return;
      if (!focused) {
        _setFailed(kCouldNotFocusReason);
        _refuse(kCouldNotFocusReason);
        return;
      }
    }

    final ScreenSharePeer peer;
    try {
      peer = await backend.startShare(windowId);
    } catch (err) {
      if (cancelled()) return;
      final reason = 'Could not capture that window: $err';
      _setFailed(reason);
      _refuse(reason);
      return;
    }
    if (cancelled()) {
      await peer.dispose();
      return;
    }
    // The switch can go off while the capture is starting, and the revocation
    // hook fires against a peer that did not exist yet — so re-check before
    // publishing an offer rather than trusting the check above.
    if (!_policy.enabled) {
      await peer.dispose();
      _setFailed(kPolicyRevokedReason);
      _refuse(kPolicyRevokedReason);
      return;
    }

    _peer = peer;
    _targetWindowId = int.tryParse(windowId);
    _answered = false;
    _pendingRemoteCandidates.clear();
    _unaddressed.clear();
    _candidateSub = peer.localCandidates.listen(_onLocalCandidate);
    _peerStateSub = peer.peerStates.listen(_onPeerState);
    _inputSub = peer.inputMessages.listen(_onInputMessage);
    _captureEndedSub = peer.captureEnded.listen((_) {
      unawaited(
        _teardown('That window closed, so the session ended.', failed: true),
      );
    });

    final ScreenSdp offer;
    try {
      offer = await peer.createOffer();
    } catch (err) {
      if (cancelled()) return;
      await _teardown('Could not start the video session: $err', failed: true);
      return;
    }
    // From here the peer is [_peer], so a teardown in between has already
    // disposed of it.
    if (cancelled()) return;

    final size = peer.initialFrameSize;
    _setState(
      ScreenShareState(
        stage: ScreenShareStage.live,
        windowTitle: peer.windowTitle,
        frameSize: size,
      ),
    );
    _send('screen:offer', {
      'sdp': offer.sdp,
      'dtlsFingerprint': offer.dtlsFingerprint,
      // The schema requires positive dimensions; before the first frame is
      // encoded the platform may not know them, so advertise 1x1 and correct it
      // from the stats poll rather than hold the offer back.
      'width': size.width > 0 ? size.width : 1,
      'height': size.height > 0 ? size.height : 1,
    });
    _sendState(
      ScreenSessionStatus.live,
      windowTitle: peer.windowTitle,
      size: size,
    );

    await _beginInput(size);
    if (cancelled()) return;
    _frameHealthTimer = Timer.periodic(
      _frameHealthInterval,
      (_) => unawaited(checkFrameHealth()),
    );
  }

  /// The local user declined, or ended the session from this machine.
  Future<void> stopSession(String reason) => _teardown(reason);

  /// Re-reads the encoder's frame size. Exposed rather than left to the timer so
  /// a test can drive the minimised-window path without waiting on wall clock.
  Future<void> checkFrameHealth() async {
    final peer = _peer;
    if (peer == null || _state.stage != ScreenShareStage.live) return;
    final size = await peer.encodedFrameSize();
    if (size == null || size.width == 0 || size.height == 0) {
      // Only counted once a viewer is connected: before that there is nothing to
      // send frames to, and a session waiting for its first viewer is healthy.
      if (!_state.viewerConnected) return;
      if (++_framelessPolls < kMaxFramelessPolls) return;
      await _teardown(kNoFramesReason, failed: true);
      return;
    }
    _framelessPolls = 0;
    if (size.isCollapsed) {
      await _teardown(kMinimisedReason, failed: true);
      return;
    }
    if (size == _state.frameSize) return;
    _setState(_state.copyWith(frameSize: size));
    _sendState(
      ScreenSessionStatus.live,
      windowTitle: _state.windowTitle,
      size: size,
    );
    // This poll is where a platform that never reported a track size learns one,
    // so it is also the only moment input can still begin — re-aiming alone
    // would leave the session view-only for its whole life.
    if (_awaitingFrameSize) {
      await _beginInput(size);
    } else {
      _retargetInput(size);
    }
  }

  // --- Input ---

  /// Consecutive frame-health polls that found no encoded frame while a viewer
  /// was connected. See [kNoFramesReason]: a capture that never starts is
  /// otherwise indistinguishable from one that is about to.
  int _framelessPolls = 0;

  /// Whether input is deferred purely because the frame size is not known yet.
  ///
  /// Distinct from "input failed": an injector that refused the target is not
  /// retried on every stats poll, but a size that simply had not arrived is.
  bool _awaitingFrameSize = false;

  /// Binds remote input to the target, if it can be bound yet.
  ///
  /// Runs at offer time and again from [checkFrameHealth]: a platform whose
  /// track reports its dimensions gets control immediately, and one that only
  /// publishes them in encoder stats gets it on the first poll instead.
  Future<void> _beginInput(ScreenFrameSize size) async {
    final injector = _injector;
    final windowId = _targetWindowId;
    if (injector == null || windowId == null) {
      _awaitingFrameSize = false;
      _setState(
        _state.copyWith(
          inputActive: false,
          reason: 'Remote control is not available on this machine.',
        ),
      );
      return;
    }
    if (size.width <= 0 || size.height <= 0) {
      _awaitingFrameSize = true;
      _setState(
        _state.copyWith(inputActive: false, reason: kAwaitingFrameSizeReason),
      );
      return;
    }
    _awaitingFrameSize = false;
    final transform = _buildTransform(windowId, size);
    if (transform == null) {
      _setState(
        _state.copyWith(inputActive: false, reason: kWindowOffScreenReason),
      );
      return;
    }
    final generation = _generation;
    try {
      await injector.beginSession(
        targetWindowId: windowId,
        transform: transform,
      );
      // The session ended while the injector was arming, and its teardown's
      // `endSession` may already have run — so this disarms it again.
      if (generation != _generation) {
        await injector.endSession();
        return;
      }
      _setState(_state.copyWith(inputActive: true, clearReason: true));
    } on InputInjectionException catch (err) {
      // Viewing without control is still worth having, so this degrades the
      // session rather than ending it — but the reason must reach the user, or
      // "my clicks do nothing" is unexplainable.
      _setState(_state.copyWith(inputActive: false, reason: err.message));
    }
  }

  /// [size] must already be known-positive: callers separate "no frame size yet"
  /// from this, so a null here means one thing only — the window has no screen
  /// origin, which is not a state that resolves on its own.
  FrameToScreenTransform? _buildTransform(int windowId, ScreenFrameSize size) {
    final origin = _windowOrigin(windowId);
    if (origin == null) return null;
    return FrameToScreenTransform.forCapturedWindow(
      frameWidth: size.width,
      frameHeight: size.height,
      windowLeft: origin.x,
      windowTop: origin.y,
    );
  }

  void _retargetInput(ScreenFrameSize size) {
    final windowId = _targetWindowId;
    if (windowId == null || !_state.inputActive) return;
    final transform = _buildTransform(windowId, size);
    if (transform == null) return;
    _injector?.updateTransform(transform);
  }

  /// True while [InputInjector.ensureForeground] is in flight. Raising is
  /// asynchronous — it hops to a worker isolate — and the events that land
  /// meanwhile must not overtake the press that triggered it.
  bool _raising = false;

  /// Input held for the duration of a raise, replayed in arrival order once it
  /// settles.
  ///
  /// Injecting these as they arrive would not merely reorder them: until the
  /// raise lands the injector refuses everything, so a press that raised and a
  /// release that did not would leave the target holding a button down with
  /// nothing to release it. Bounded because a raise can time out at two seconds
  /// and a viewer dragging emits continuously.
  final List<Map<String, dynamic>> _deferredInput = [];
  static const int _deferredInputCap = 64;

  /// One datachannel payload from the remote peer. Everything here is untrusted:
  /// a malformed frame is dropped silently rather than allowed to throw on the
  /// stream's error path.
  void _onInputMessage(String payload) {
    final injector = _injector;
    if (injector == null || !_state.inputActive) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (_raising) {
      if (_deferredInput.length < _deferredInputCap) {
        _deferredInput.add(decoded);
      }
      return;
    }
    // `SendInput` is system-wide, so the injector refuses every event while the
    // target does not hold the foreground — which is true from the moment the
    // local user clicks anything else. Re-raising on a press is what keeps the
    // session from going silently view-only; without it, one click at the host
    // machine ends remote control for good.
    if (decoded['t'] == 'down' && !injector.targetIsForeground) {
      unawaited(_raiseAndApply(injector, decoded));
      return;
    }
    _applyInput(injector, decoded);
  }

  /// Raises the target, then replays [press] and anything that queued behind it.
  ///
  /// Only a press gets here. A move or a key must never steal the desktop: a
  /// cursor drifting across a shared window would otherwise yank focus away from
  /// whoever is sitting at that machine, and a press is the same gesture that
  /// would raise the window for them.
  Future<void> _raiseAndApply(
    InputInjector injector,
    Map<String, dynamic> press,
  ) async {
    _raising = true;
    final bool raised;
    try {
      raised = await injector.ensureForeground();
    } finally {
      _raising = false;
    }
    final deferred = List.of(_deferredInput);
    _deferredInput.clear();
    // The session can end, or lose input, across the raise — replaying into a
    // torn-down injector would aim at whatever now holds the foreground.
    if (_disposed || !_state.inputActive) return;
    if (!raised) {
      _setState(_state.copyWith(reason: kForegroundRaiseDeniedReason));
      return;
    }
    if (_state.reason == kForegroundRaiseDeniedReason) {
      _setState(_state.copyWith(clearReason: true));
    }
    _applyInput(injector, press);
    for (final event in deferred) {
      _applyInput(injector, event);
    }
  }

  void _applyInput(InputInjector injector, Map<String, dynamic> event) {
    final type = event['t'];
    final vk = event['vk'];
    final text = event['s'];
    if (type == 'key' && vk is int) {
      injector.injectKey(
        KeyInput(virtualKeyCode: vk, down: event['down'] == true),
      );
      return;
    }
    if (type == 'text' && text is String) {
      injector.injectText(text);
      return;
    }
    // Everything below is positioned. An event without a usable position cannot
    // be placed on screen, so it is dropped rather than aimed at the origin.
    final x = event['x'];
    final y = event['y'];
    if (x is! num || y is! num) return;
    final action = switch (type) {
      'move' => PointerAction.move,
      'down' => PointerAction.down,
      'up' => PointerAction.up,
      _ => null,
    };
    if (action != null) {
      injector.injectPointer(
        PointerInput(
          action: action,
          frameX: x.toDouble(),
          frameY: y.toDouble(),
          button: _button(event['b']),
        ),
      );
      return;
    }
    if (type == 'scroll') {
      injector.injectScroll(
        ScrollInput(
          frameX: x.toDouble(),
          frameY: y.toDouble(),
          deltaX: (event['dx'] as num?)?.toDouble() ?? 0,
          deltaY: (event['dy'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
  }

  PointerButton _button(Object? raw) => switch (raw) {
    'right' => PointerButton.right,
    'middle' => PointerButton.middle,
    _ => PointerButton.left,
  };

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
        _recoveryTimer?.cancel();
        _recoveryTimer = null;
        if (_state.stage == ScreenShareStage.interrupted) {
          _setState(
            _state.copyWith(
              stage: ScreenShareStage.live,
              viewerConnected: true,
              clearReason: true,
            ),
          );
          _sendState(
            ScreenSessionStatus.live,
            windowTitle: _state.windowTitle,
            size: _state.frameSize,
          );
        } else if (!_state.viewerConnected) {
          // No `_sendState`: this is the first viewer arriving, and the only
          // peer it could be told about is that viewer itself — which learns it
          // from its own connection coming up.
          _setState(_state.copyWith(viewerConnected: true));
        }
        unawaited(_verifyNegotiatedFingerprint());
      case ScreenPeerState.disconnected:
        // Recoverable — ICE routinely passes through this on a network change —
        // so it is a state rather than an end. But it has to reach the viewer:
        // silence here leaves it rendering the last frame it received and
        // calling that live.
        if (_state.stage != ScreenShareStage.live) return;
        _setState(
          _state.copyWith(
            stage: ScreenShareStage.interrupted,
            reason: kPeerInterruptedReason,
          ),
        );
        _sendState(
          ScreenSessionStatus.interrupted,
          reason: kPeerInterruptedReason,
          windowTitle: _state.windowTitle,
          size: _state.frameSize,
        );
        _recoveryTimer = Timer(
          _peerRecoveryGrace,
          () => unawaited(_teardown(kPeerRecoveryTimedOutReason, failed: true)),
        );
      case ScreenPeerState.failed:
      case ScreenPeerState.closed:
        unawaited(_teardown(kPeerLostReason, failed: true));
      case ScreenPeerState.connecting:
        break;
    }
  }

  /// Ends the session. Detaching the peer happens FIRST and synchronously: the
  /// datachannel carrying remote input is invisible to every bridge-side gate,
  /// so nothing may be awaited between deciding to stop and the last moment an
  /// injected event could still get through.
  ///
  /// [keepViewer] is for a session being replaced by another for the same
  /// viewer; every other end frees the session for whichever viewer asks next.
  Future<void> _teardown(
    String reason, {
    bool failed = false,
    bool notifyPeer = true,
    bool keepViewer = false,
  }) async {
    _generation++;
    final peer = _peer;
    _peer = null;
    // Released before anything is awaited, so a request landing mid-teardown
    // opens a fresh session rather than being refused as busy by one that is
    // already over. The goodbye below still goes to the viewer this one had.
    final viewerId = _viewerId;
    if (!keepViewer) _viewerId = null;
    _frameHealthTimer?.cancel();
    _frameHealthTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    // Detach the input path first and without awaiting it. Cancelling a
    // broadcast subscription takes effect immediately, so this is the line that
    // closes the window between deciding to stop and the peer actually going
    // away — everything after it is cleanup.
    unawaited(_inputSub?.cancel() ?? Future<void>.value());
    _inputSub = null;
    final subs = [_candidateSub, _peerStateSub, _captureEndedSub];
    _candidateSub = null;
    _peerStateSub = null;
    _captureEndedSub = null;
    _answered = false;
    _viewerFingerprint = null;
    _fingerprintVerified = false;
    _pendingRemoteCandidates.clear();
    _unaddressed.clear();
    _deferredInput.clear();
    _offeredWindowIds.clear();
    _targetWindowId = null;
    _framelessPolls = 0;
    _awaitingFrameSize = false;

    if (peer == null && _state.stage == ScreenShareStage.idle) return;

    _setState(
      failed
          ? ScreenShareState(stage: ScreenShareStage.failed, reason: reason)
          : const ScreenShareState(),
    );

    await peer?.dispose();
    for (final sub in subs) {
      await sub?.cancel();
    }
    await _injector?.endSession();

    if (notifyPeer && !_disposed && viewerId != null) {
      _send('screen:stop', {'reason': reason}, to: viewerId);
      _sendState(ScreenSessionStatus.ended, reason: reason, to: viewerId);
    }
  }

  // --- Outbound ---

  /// Ends a request that never reached a peer connection — so there is nothing
  /// for [_teardown] to dismantle — and frees the session for the next viewer.
  void _refuse(String reason) {
    _sendState(ScreenSessionStatus.ended, reason: reason);
    _viewerId = null;
  }

  void _sendState(
    ScreenSessionStatus status, {
    String? reason,
    String? windowTitle,
    ScreenFrameSize? size,
    String? to,
  }) {
    _send('screen:state', {
      'status': screenStatusWire(status),
      'reason': ?reason,
      if (windowTitle != null && windowTitle.isNotEmpty)
        'windowTitle': windowTitle,
      // The schema requires positive dimensions, so a not-yet-known size is
      // omitted rather than sent as zero.
      if (size != null && size.width > 0) 'width': size.width,
      if (size != null && size.height > 0) 'height': size.height,
    }, to: to);
  }

  /// Addressed to [to], or to the bound viewer when that is null.
  void _send(String type, Map<String, dynamic> payload, {String? to}) {
    if (_disposed) return;
    final viewerId = to ?? _viewerId;
    if (viewerId == null) {
      // A state needs no holding: adopting a session re-advertises it.
      if (type == 'screen:offer' || type == 'screen:ice') {
        _unaddressed.add((type, payload));
      }
      return;
    }
    unawaited(
      session.send(createAbMessage(type, {...payload, 'viewerId': viewerId})),
    );
  }

  void _setState(ScreenShareState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  void _setFailed(String reason) => _setState(
    ScreenShareState(stage: ScreenShareStage.failed, reason: reason),
  );

  Future<void> dispose() async {
    if (_disposed) return;
    await _teardown('The project closed.');
    _disposed = true;
    await _statusSub?.cancel();
    _statusSub = null;
    await _policySub?.cancel();
    _policySub = null;
    await _backend?.dispose();
    await _stateController.close();
  }
}
