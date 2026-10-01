import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/screen_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/screen_share_backend.dart';
import 'package:antgrid/services/screen_view_backend.dart';
import 'package:antgrid/services/screen_view_service.dart';
import 'package:antgrid/services/screen_viewer_input.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

String sdpWithFingerprint(String fingerprint) =>
    'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\n'
    'a=fingerprint:$fingerprint\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n';

const String kHostFingerprint = 'sha-256 AA:BB:CC:DD';
const String kViewerFingerprint = 'sha-256 11:22:33:44';

class FakeViewPeer implements ScreenViewPeer {
  final candidates = StreamController<ScreenIceCandidate>.broadcast();
  final states = StreamController<ScreenPeerState>.broadcast();
  final sizes = StreamController<ScreenFrameSize>.broadcast();

  final List<String> answeredOffers = [];
  final List<ScreenIceCandidate> addedCandidates = [];
  final List<({String payload, bool reliable})> inputs = [];
  Widget? view = const SizedBox.shrink();
  bool disposed = false;

  /// What the DTLS handshake actually settled on. Defaults to the fingerprint a
  /// well-behaved host signs for, so only the tests about substitution have to
  /// say anything about it.
  String? negotiatedFingerprint = kHostFingerprint;

  @override
  Stream<ScreenIceCandidate> get localCandidates => candidates.stream;

  @override
  Stream<ScreenPeerState> get peerStates => states.stream;

  @override
  Stream<ScreenFrameSize> get frameSizes => sizes.stream;

  @override
  Widget? get videoView => view;

  @override
  Future<ScreenSdp> answerOffer(String offerSdp) async {
    answeredOffers.add(offerSdp);
    return ScreenSdp(
      sdp: sdpWithFingerprint(kViewerFingerprint),
      dtlsFingerprint: kViewerFingerprint,
    );
  }

  @override
  Future<void> addRemoteCandidate(ScreenIceCandidate candidate) async =>
      addedCandidates.add(candidate);

  @override
  bool sendInput(String payload, {required bool reliable}) {
    inputs.add((payload: payload, reliable: reliable));
    return true;
  }

  @override
  Future<String?> remoteFingerprint() async => negotiatedFingerprint;

  @override
  Future<void> dispose() async {
    disposed = true;
    await candidates.close();
    await states.close();
    await sizes.close();
  }
}

class FakeViewBackend implements ScreenViewBackend {
  FakeViewBackend({FakeViewPeer? peer}) : peer = peer ?? FakeViewPeer();

  final FakeViewPeer peer;
  int createCalls = 0;
  Object? createError;

  @override
  Future<ScreenViewPeer> createPeer() async {
    createCalls++;
    final error = createError;
    if (error != null) throw error;
    return peer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<ProjectSession> newSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.relay,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
    // ProjectSession builds its own pair of screen services, which would answer
    // the same frames the SUT does and double every outbound assertion.
    await session.screenViewService.dispose();
    await session.screenShareService.dispose();
    t.clearSent();
    return session;
  }

  Map<String, dynamic>? lastOf(FakeAgentTransport t, String type) {
    final matches = t.sent.where((m) => m['type'] == type);
    return matches.isEmpty ? null : matches.last;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void emitOffer(
    FakeAgentTransport t, {
    String fingerprint = kHostFingerprint,
    String? claimed,
    int width = 1440,
    int height = 900,
  }) => t.emit('screen:offer', {
    'sdp': sdpWithFingerprint(fingerprint),
    'dtlsFingerprint': claimed ?? fingerprint,
    'width': width,
    'height': height,
  });

  /// Drive a session to live so the tests that need media start from a real
  /// negotiated peer rather than an assumed one.
  Future<({ScreenViewService service, FakeViewBackend backend})> liveViewer(
    FakeAgentTransport t, {
    FakeViewBackend? backend,
  }) async {
    final session = await newSession(t);
    backend ??= FakeViewBackend();
    final service = ScreenViewService.fromSession(
      session,
      backend: backend,
      fingerprintProbeInterval: Duration.zero,
    );
    await service.requestSession();
    emitOffer(t);
    await settle();
    backend.peer.states.add(ScreenPeerState.connected);
    await settle();
    return (service: service, backend: backend);
  }

  test('a loopback session never views — it is the host side', () async {
    // The stock fake reports a remote transport, which is exactly the viewer
    // case; the host side of this feature lives on the loopback one.
    final t = LocalFakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    expect(service.canView, isFalse);
    await service.requestSession();

    expect(service.currentState.stage, ScreenViewStage.unsupported);
    expect(service.currentState.reason, kViewerLocalSessionReason);
    expect(lastOf(t, 'screen:request'), isNull);
    await service.dispose();
  });

  test('requestSession sends screen:request and waits', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    await service.requestSession();

    expect(service.currentState.stage, ScreenViewStage.requesting);
    expect(lastOf(t, 'screen:request')?['projectId'], 'p');
    await service.dispose();
  });

  test('the request says which end picks the window', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    await service.requestSession();
    expect(lastOf(t, 'screen:request')?['chooser'], 'viewer');

    await service.requestSession(chooser: ScreenChooser.host);
    expect(lastOf(t, 'screen:request')?['chooser'], 'host');

    await service.dispose();
  });

  test('a published catalog becomes the pick, and the pick names it', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    await service.requestSession();
    t.emit('screen:windows', {
      'windows': [
        {'id': '11', 'title': 'Claude'},
        {'id': '22', 'title': 'Ledger'},
      ],
    });
    await settle();

    expect(service.currentState.stage, ScreenViewStage.choosingWindow);
    expect(service.currentState.windows.map((w) => w.title), [
      'Claude',
      'Ledger',
    ]);

    service.pickWindow('22');
    expect(lastOf(t, 'screen:pick')?['windowId'], '22');
    expect(service.currentState.stage, ScreenViewStage.connecting);
    // The title comes from the catalog, so the connecting state can name the
    // window before the host has said anything about it.
    expect(service.currentState.windowTitle, 'Ledger');

    await service.dispose();
  });

  test('a window outside the catalog is never picked', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    await service.requestSession();
    t.emit('screen:windows', {
      'windows': [
        {'id': '11', 'title': 'Claude'},
      ],
    });
    await settle();

    service.pickWindow('99');
    expect(lastOf(t, 'screen:pick'), isNull);
    expect(service.currentState.stage, ScreenViewStage.choosingWindow);

    await service.dispose();
  });

  test('a catalog arriving mid-session does not discard the picture', () async {
    final t = FakeAgentTransport();
    final viewer = await liveViewer(t);

    t.emit('screen:windows', {
      'windows': [
        {'id': '11', 'title': 'Claude'},
      ],
    });
    await settle();

    expect(viewer.service.currentState.stage, ScreenViewStage.live);

    await viewer.service.dispose();
  });

  test('every wire status lands on a named stage', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    t.emit('screen:state', {'status': 'no-host'});
    await settle();
    expect(service.currentState.stage, ScreenViewStage.noHost);

    t.emit('screen:state', {'status': 'awaiting-consent'});
    await settle();
    expect(service.currentState.stage, ScreenViewStage.awaitingConsent);

    t.emit('screen:state', {
      'status': 'live',
      'windowTitle': 'Notepad',
      'width': 800,
      'height': 600,
    });
    await settle();
    // Live-on-the-wire is not live-on-screen: the host publishes it the moment
    // it has an offer, which is before any media exists.
    expect(service.currentState.stage, ScreenViewStage.connecting);
    expect(service.currentState.windowTitle, 'Notepad');
    expect(service.currentState.frameSize, const ScreenFrameSize(800, 600));

    t.emit('screen:state', {'status': 'interrupted', 'reason': 'path lost'});
    await settle();
    expect(service.currentState.stage, ScreenViewStage.interrupted);
    expect(service.currentState.reason, 'path lost');

    t.emit('screen:state', {'status': 'ended', 'reason': 'host stopped'});
    await settle();
    expect(service.currentState.stage, ScreenViewStage.ended);
    expect(service.currentState.reason, 'host stopped');

    t.emit('screen:state', {'status': 'idle'});
    await settle();
    expect(service.currentState.stage, ScreenViewStage.idle);

    await service.dispose();
  });

  test(
    'an offer whose SDP contradicts its signed fingerprint is refused',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeViewBackend();
      final service = ScreenViewService.fromSession(session, backend: backend);
      await service.requestSession();

      emitOffer(
        t,
        fingerprint: kHostFingerprint,
        claimed: 'sha-256 DE:AD:BE:EF',
      );
      await settle();

      // Aborting rather than warning is the point: this is the viewer half of the
      // binding that shuts out a MITM on the signalling path.
      expect(backend.createCalls, 0);
      expect(lastOf(t, 'screen:answer'), isNull);
      expect(service.currentState.stage, ScreenViewStage.ended);
      expect(service.currentState.reason, kFingerprintMismatchReason);
      expect(lastOf(t, 'screen:stop')?['reason'], kFingerprintMismatchReason);
      await service.dispose();
    },
  );

  test(
    'a matching offer is answered with the negotiated fingerprint',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeViewBackend();
      final service = ScreenViewService.fromSession(session, backend: backend);
      await service.requestSession();

      emitOffer(t);
      await settle();

      expect(backend.peer.answeredOffers.single, contains(kHostFingerprint));
      final answer = lastOf(t, 'screen:answer');
      expect(answer?['dtlsFingerprint'], kViewerFingerprint);
      expect(answer?['sdp'], contains(kViewerFingerprint));
      expect(service.currentState.stage, ScreenViewStage.connecting);
      expect(service.currentState.frameSize, const ScreenFrameSize(1440, 900));
      await service.dispose();
    },
  );

  test(
    'a 1x1 offer size is ignored so the first paint is not a pixel',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeViewBackend();
      final service = ScreenViewService.fromSession(session, backend: backend);
      await service.requestSession();

      emitOffer(t, width: 1, height: 1);
      await settle();
      expect(service.currentState.frameSize, isNull);

      backend.peer.sizes.add(const ScreenFrameSize(1280, 720));
      await settle();
      expect(service.currentState.frameSize, const ScreenFrameSize(1280, 720));
      await service.dispose();
    },
  );

  test(
    'candidates that arrive before the answer are buffered, not dropped',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeViewBackend();
      final service = ScreenViewService.fromSession(session, backend: backend);
      await service.requestSession();

      t.emit('screen:ice', {'candidate': 'early', 'sdpMLineIndex': 0});
      await settle();
      expect(backend.peer.addedCandidates, isEmpty);

      emitOffer(t);
      await settle();

      expect(backend.peer.addedCandidates.single.candidate, 'early');

      t.emit('screen:ice', {'candidate': 'late'});
      await settle();
      expect(backend.peer.addedCandidates.map((c) => c.candidate), [
        'early',
        'late',
      ]);
      await service.dispose();
    },
  );

  test('local candidates go out as screen:ice', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);

    live.backend.peer.candidates.add(
      const ScreenIceCandidate(
        candidate: 'candidate:1',
        sdpMid: '0',
        sdpMLineIndex: 0,
      ),
    );
    await settle();

    expect(lastOf(t, 'screen:ice')?['candidate'], 'candidate:1');
    expect(lastOf(t, 'screen:ice')?['sdpMid'], '0');
    await live.service.dispose();
  });

  test('the peer connecting is what promotes the session to live', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);
    expect(live.service.currentState.stage, ScreenViewStage.live);
    await live.service.dispose();
  });

  test('a lost peer ends the session and disposes it', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);

    live.backend.peer.states.add(ScreenPeerState.failed);
    await settle();

    expect(live.service.currentState.stage, ScreenViewStage.ended);
    expect(live.service.currentState.reason, kViewerPeerLostReason);
    expect(live.backend.peer.disposed, isTrue);
    await live.service.dispose();
  });

  test(
    'an ICE disconnect is a stated pause, and input stops with it',
    () async {
      final t = FakeAgentTransport();
      final live = await liveViewer(t);

      live.backend.peer.states.add(ScreenPeerState.disconnected);
      await settle();

      expect(live.service.currentState.stage, ScreenViewStage.interrupted);
      expect(live.service.currentState.reason, kViewerInterruptedReason);
      expect(live.backend.peer.disposed, isFalse);
      // Driving a frozen picture aims at where the window used to be.
      live.service.sendKey(0x41, down: true);
      expect(live.backend.peer.inputs, isEmpty);

      live.backend.peer.states.add(ScreenPeerState.connected);
      await settle();
      expect(live.service.currentState.stage, ScreenViewStage.live);
      expect(live.service.currentState.reason, isNull);

      await live.service.dispose();
    },
  );

  test('a substituted media certificate stops the session', () async {
    // The mirror of the host's check. The signalling path can rewrite the SDP,
    // so a sealed offer that agrees with the SDP is not enough on its own — the
    // certificate DTLS accepted has to be the one the host signed for.
    final t = FakeAgentTransport();
    final backend = FakeViewBackend();
    backend.peer.negotiatedFingerprint = 'sha-256 99:88:77:66';
    final live = await liveViewer(t, backend: backend);

    expect(live.service.currentState.stage, ScreenViewStage.ended);
    expect(live.service.currentState.reason, kHostCertificateMismatchReason);
    expect(backend.peer.disposed, isTrue);
    expect(lastOf(t, 'screen:stop')?['reason'], kHostCertificateMismatchReason);
    await live.service.dispose();
  });

  test('a certificate the peer never reports leaves the session up', () async {
    final t = FakeAgentTransport();
    final backend = FakeViewBackend();
    backend.peer.negotiatedFingerprint = null;
    final live = await liveViewer(t, backend: backend);

    expect(live.service.currentState.stage, ScreenViewStage.live);
    expect(backend.peer.disposed, isFalse);
    await live.service.dispose();
  });

  test(
    'a remote screen:stop ends the session with the host\'s reason',
    () async {
      final t = FakeAgentTransport();
      final live = await liveViewer(t);

      t.emit('screen:stop', {'reason': 'That window was minimised.'});
      await settle();

      expect(live.service.currentState.stage, ScreenViewStage.ended);
      expect(live.service.currentState.reason, 'That window was minimised.');
      expect(live.backend.peer.disposed, isTrue);
      await live.service.dispose();
    },
  );

  test('input rides the datachannel, with motion on the lossy one', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);
    final peer = live.backend.peer;

    live.service.sendPointer(
      action: ViewerPointerAction.move,
      frame: const Offset(10, 20),
    );
    live.service.sendPointer(
      action: ViewerPointerAction.down,
      frame: const Offset(10, 20),
      button: 'right',
    );
    live.service.sendKey(0x25, down: true);
    live.service.sendText('hi');
    live.service.sendScroll(frame: const Offset(1, 2), deltaY: -1);

    expect(peer.inputs.map((i) => i.reliable), [false, true, true, true, true]);
    expect(jsonDecode(peer.inputs.first.payload), {
      't': 'move',
      'x': 10.0,
      'y': 20.0,
      'b': 'left',
    });
    // Nothing about the input path touches the bridge, so it must never reach
    // the signalling channel either.
    expect(t.sent.where((m) => m['type'] == 'screen:input'), isEmpty);
    await live.service.dispose();
  });

  test(
    'input is dropped while control is off or the session is not live',
    () async {
      final t = FakeAgentTransport();
      final live = await liveViewer(t);
      final peer = live.backend.peer;

      live.service.setControlEnabled(false);
      live.service.sendKey(0x41, down: true);
      expect(peer.inputs, isEmpty);
      expect(live.service.currentState.controlEnabled, isFalse);

      live.service.setControlEnabled(true);
      await live.service.stopSession('done');
      live.service.sendKey(0x41, down: true);
      expect(peer.inputs, isEmpty);
      await live.service.dispose();
    },
  );

  test('stopSession tells the host and tears the peer down', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);

    await live.service.stopSession('Stopped from the viewer');

    expect(lastOf(t, 'screen:stop')?['reason'], 'Stopped from the viewer');
    expect(live.backend.peer.disposed, isTrue);
    expect(live.service.currentState.stage, ScreenViewStage.idle);
    await live.service.dispose();
  });

  test('a second offer replaces the first peer rather than stacking', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final first = FakeViewPeer();
    final backend = FakeViewBackend(peer: first);
    final service = ScreenViewService.fromSession(session, backend: backend);
    await service.requestSession();

    emitOffer(t);
    await settle();
    emitOffer(t);
    await settle();

    expect(first.disposed, isTrue);
    expect(backend.createCalls, 2);
    await service.dispose();
  });

  test('a backend failure surfaces as an ended session, not a throw', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final backend = FakeViewBackend()..createError = StateError('no webrtc');
    final service = ScreenViewService.fromSession(session, backend: backend);
    await service.requestSession();

    emitOffer(t);
    await settle();

    expect(service.currentState.stage, ScreenViewStage.ended);
    expect(service.currentState.reason, contains('no webrtc'));
    await service.dispose();
  });

  test('the host going away mid-session drops the picture at once', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);

    // The bridge's word that the desktop app disconnected, sent without waiting
    // for ICE to notice the path is gone.
    t.emit('screen:state', {'status': 'no-host', 'viewerId': 'peer-1'});
    await settle();

    expect(live.service.currentState.stage, ScreenViewStage.noHost);
    expect(live.backend.peer.disposed, isTrue);
    live.service.sendKey(0x41, down: true);
    expect(live.backend.peer.inputs, isEmpty);
    await live.service.dispose();
  });

  test('a switch turned off on the host ends the session in words', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);

    t.emit('screen:state', {
      'status': 'ended',
      'reason': 'screen control turned off',
      'viewerId': 'peer-1',
    });
    await settle();

    expect(live.service.currentState.stage, ScreenViewStage.ended);
    expect(live.service.currentState.reason, kViewerScreenControlOffReason);
    expect(live.backend.peer.disposed, isTrue);

    await live.service.requestSession();
    t.emit('screen:state', {
      'status': 'ended',
      'reason': 'remote access turned off',
    });
    await settle();
    expect(live.service.currentState.reason, kViewerRemoteAccessOffReason);

    await live.service.dispose();
  });

  test('an ended state always explains itself', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final service = ScreenViewService.fromSession(
      session,
      backend: FakeViewBackend(),
    );

    t.emit('screen:state', {'status': 'ended'});
    await settle();
    expect(service.currentState.stage, ScreenViewStage.ended);
    expect(service.currentState.reason, kViewerHostEndedReason);

    // The host's own reasons are already written for the user.
    t.emit('screen:state', {'status': 'ended', 'reason': 'Nothing to share.'});
    await settle();
    expect(service.currentState.reason, 'Nothing to share.');

    await service.dispose();
  });

  test('outbound signalling never names a viewer', () async {
    // The bridge stamps the viewer's authenticated peer id on the way in and
    // overwrites anything sent here, so claiming one would only mislead.
    final t = FakeAgentTransport();
    final live = await liveViewer(t);
    live.backend.peer.candidates.add(
      const ScreenIceCandidate(candidate: 'candidate:1'),
    );
    await settle();
    await live.service.stopSession('done');

    final screenFrames = t.sent.where(
      (m) => (m['type'] as String).startsWith('screen:'),
    );
    expect(screenFrames.map((m) => m['type']), [
      'screen:request',
      'screen:answer',
      'screen:ice',
      'screen:stop',
    ]);
    expect(screenFrames.where((m) => m.containsKey('viewerId')), isEmpty);
    await live.service.dispose();
  });

  test('dispose tears the peer down and stops emitting', () async {
    final t = FakeAgentTransport();
    final live = await liveViewer(t);

    await live.service.dispose();

    expect(live.backend.peer.disposed, isTrue);
    t.emit('screen:state', {'status': 'no-host'});
    await settle();
    // A disposed service stops reacting entirely rather than settling into some
    // final state — the last state it published is the last one there will be.
    expect(live.service.currentState.stage, ScreenViewStage.live);
  });
}
