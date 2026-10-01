import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/native/input_injector.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/screen_share_backend.dart';
import 'package:antgrid/services/screen_share_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

/// A minimal SDP carrying only what the service reads out of one.
String sdpWithFingerprint(String fingerprint) =>
    'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\n'
    'a=fingerprint:$fingerprint\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n';

const String kHostFingerprint = 'sha-256 AA:BB:CC:DD';
const String kViewerFingerprint = 'sha-256 11:22:33:44';

/// The Iroh peer id the bridge stamps on the viewer's frames.
const String kViewer = 'viewer-a';
const String kOtherViewer = 'viewer-b';

/// A frame as the bridge hands it to the host: stamped with the sender's id.
void fromViewer(
  FakeAgentTransport t,
  String type, [
  Map<String, dynamic> extra = const {},
  String viewerId = kViewer,
]) => t.emit(type, {...extra, 'viewerId': viewerId});

class FakePolicy implements ScreenControlPolicy {
  FakePolicy({bool enabled = true}) : _enabled = enabled;

  bool _enabled;
  final _controller = StreamController<bool>.broadcast();

  @override
  bool get enabled => _enabled;

  @override
  Stream<bool> get changes => _controller.stream;

  void set(bool value) {
    _enabled = value;
    _controller.add(value);
  }

  Future<void> close() => _controller.close();
}

class FakePeer implements ScreenSharePeer {
  FakePeer({this.frameSize = const ScreenFrameSize(1440, 900)});

  final candidates = StreamController<ScreenIceCandidate>.broadcast();
  final states = StreamController<ScreenPeerState>.broadcast();
  final input = StreamController<String>.broadcast();
  final ended = StreamController<void>.broadcast();

  ScreenFrameSize frameSize;
  ScreenFrameSize? statsSize;

  /// What the DTLS handshake actually settled on. Defaults to the fingerprint a
  /// well-behaved viewer signs for, so only the tests about substitution have to
  /// say anything about it.
  String? negotiatedFingerprint = kViewerFingerprint;
  final List<String> acceptedAnswers = [];
  final List<ScreenIceCandidate> addedCandidates = [];
  bool disposed = false;

  @override
  String get windowTitle => 'Notepad';

  @override
  ScreenFrameSize get initialFrameSize => frameSize;

  @override
  Stream<ScreenIceCandidate> get localCandidates => candidates.stream;

  @override
  Stream<ScreenPeerState> get peerStates => states.stream;

  @override
  Stream<String> get inputMessages => input.stream;

  @override
  Stream<void> get captureEnded => ended.stream;

  @override
  Future<ScreenSdp> createOffer() async => ScreenSdp(
    sdp: sdpWithFingerprint(kHostFingerprint),
    dtlsFingerprint: kHostFingerprint,
  );

  @override
  Future<void> acceptAnswer(String sdp) async => acceptedAnswers.add(sdp);

  @override
  Future<void> addRemoteCandidate(ScreenIceCandidate candidate) async =>
      addedCandidates.add(candidate);

  @override
  Future<ScreenFrameSize?> encodedFrameSize() async => statsSize;

  @override
  Future<String?> remoteFingerprint() async => negotiatedFingerprint;

  @override
  Future<void> dispose() async {
    disposed = true;
    await candidates.close();
    await states.close();
    await input.close();
    await ended.close();
  }
}

class FakeBackend implements ScreenShareBackend {
  FakeBackend({FakePeer? peer}) : peer = peer ?? FakePeer();

  final FakePeer peer;
  final _updates = StreamController<ScreenWindow>.broadcast();
  Object? startError;
  final List<String> startedWindows = [];
  bool disposed = false;

  @override
  Stream<ScreenWindow> get windowUpdates => _updates.stream;

  List<ScreenWindow> windows = const [
    ScreenWindow(id: '4242', title: 'Notepad'),
  ];

  /// Holds the enumeration open until a test completes it, for the races
  /// against a viewer leaving mid-listing.
  Completer<List<ScreenWindow>>? listGate;

  @override
  Future<List<ScreenWindow>> listWindows() async =>
      listGate == null ? windows : listGate!.future;

  @override
  Future<ScreenSharePeer> startShare(String windowId) async {
    startedWindows.add(windowId);
    final error = startError;
    if (error != null) throw error;
    return peer;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _updates.close();
  }
}

class FakeInjector implements InputInjector {
  final List<PointerInput> pointers = [];
  final List<ScrollInput> scrolls = [];
  final List<KeyInput> keys = [];
  final List<String> texts = [];
  final List<FrameToScreenTransform> transforms = [];
  int? boundWindow;
  int endSessionCalls = 0;
  InputInjectionException? beginError;

  @override
  bool get isActive => boundWindow != null;

  @override
  Future<void> beginSession({
    required int targetWindowId,
    required FrameToScreenTransform transform,
  }) async {
    final error = beginError;
    if (error != null) throw error;
    boundWindow = targetWindowId;
    transforms.add(transform);
  }

  @override
  void updateTransform(FrameToScreenTransform transform) =>
      transforms.add(transform);

  /// Whether the target currently holds the foreground. Settable so a test can
  /// stage the case the real injector hits constantly: the local user clicked
  /// something else, and every event is refused until a raise puts it back.
  bool foreground = true;

  /// What [ensureForeground] resolves to, and whether it takes a turn to do it.
  bool raiseSucceeds = true;
  int raiseCalls = 0;
  Completer<bool>? pendingRaise;

  @override
  bool get targetIsForeground => foreground;

  @override
  Future<bool> ensureForeground() async {
    raiseCalls++;
    final gate = pendingRaise;
    final ok = gate == null ? raiseSucceeds : await gate.future;
    if (ok) foreground = true;
    return ok;
  }

  @override
  Future<void> endSession() async {
    endSessionCalls++;
    boundWindow = null;
  }

  @override
  bool injectPointer(PointerInput event) {
    pointers.add(event);
    return true;
  }

  @override
  bool injectScroll(ScrollInput event) {
    scrolls.add(event);
    return true;
  }

  @override
  bool injectKey(KeyInput event) {
    keys.add(event);
    return true;
  }

  @override
  bool injectText(String text) {
    texts.add(text);
    return true;
  }
}

/// Default probe for the tests: every window sits at a known screen origin, so
/// only the tests about a window that is NOT on screen say anything about it.
ScreenPoint? _originAt100x200(int windowId) => const ScreenPoint(100, 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<ProjectSession> newSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
    // ProjectSession builds its own ScreenShareService, which would answer the
    // same frames the SUT does and double every outbound assertion. Retire it so
    // each test drives exactly one host.
    await session.screenShareService.dispose();
    t.clearSent();
    return session;
  }

  ({
    ScreenShareService service,
    FakeBackend backend,
    FakePolicy policy,
    FakeInjector injector,
  })
  buildHost(
    ProjectSession session, {
    FakePolicy? policy,
    FakeBackend? backend,
    bool withPolicy = true,
    WindowOriginProbe windowOrigin = _originAt100x200,
    WindowCapturePrep? prepareWindow,
    List<int>? preparedWindows,
    Duration peerRecoveryGrace = const Duration(hours: 1),
  }) {
    final p = policy ?? FakePolicy();
    final b = backend ?? FakeBackend();
    final i = FakeInjector();
    return (
      service: ScreenShareService.fromSession(
        session,
        policy: withPolicy ? p : null,
        backend: b,
        injector: i,
        windowOrigin: windowOrigin,
        prepareWindow:
            prepareWindow ??
            (id) async {
              preparedWindows?.add(id);
              return true;
            },
        // The health poll is driven explicitly by checkFrameHealth in the tests
        // that care; a live timer would make every other test race it. Same for
        // the recovery grace, which only the test about it shortens.
        frameHealthInterval: const Duration(hours: 1),
        peerRecoveryGrace: peerRecoveryGrace,
        fingerprintProbeInterval: Duration.zero,
      ),
      backend: b,
      policy: p,
      injector: i,
    );
  }

  Map<String, dynamic>? lastOf(FakeAgentTransport t, String type) {
    final matches = t.sent.where((m) => m['type'] == type);
    return matches.isEmpty ? null : matches.last;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Take a session all the way to live, so the teardown tests start from a real
  /// peer connection rather than an assumed one.
  Future<
    ({
      ScreenShareService service,
      FakeBackend backend,
      FakePolicy policy,
      FakeInjector injector,
    })
  >
  liveHost(
    ProjectSession session,
    FakeAgentTransport t, {
    FakeBackend? backend,
    Duration peerRecoveryGrace = const Duration(hours: 1),
  }) async {
    final host = buildHost(
      session,
      backend: backend,
      peerRecoveryGrace: peerRecoveryGrace,
    );
    fromViewer(t, 'screen:request', {'projectId': 'p'});
    await settle();
    await host.service.startSession('4242');
    t.clearSent();
    return host;
  }

  /// The answer a well-behaved viewer sends: its sealed claim and its SDP agree.
  void emitAnswer(FakeAgentTransport t) => fromViewer(t, 'screen:answer', {
    'sdp': sdpWithFingerprint(kViewerFingerprint),
    'dtlsFingerprint': kViewerFingerprint,
  });

  group('viewer-chosen window', () {
    test(
      'a listing that fails after its viewer left refuses nobody else',
      () async {
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = buildHost(session);
        final gate = Completer<List<ScreenWindow>>();
        host.backend.listGate = gate;

        fromViewer(t, 'screen:request', {
          'projectId': 'p',
          'chooser': 'viewer',
        });
        await settle();
        fromViewer(t, 'screen:stop', {'reason': 'viewer-gone'});
        fromViewer(t, 'screen:request', {'projectId': 'p'}, kOtherViewer);
        await settle();
        t.clearSent();

        gate.completeError(StateError('enumeration failed'));
        await settle();

        expect(t.sent, isEmpty);
        expect(
          host.service.currentState.stage,
          ScreenShareStage.awaitingConsent,
        );
        // Still bound to the second viewer: a third is refused as busy.
        fromViewer(t, 'screen:request', {'projectId': 'p'}, 'viewer-c');
        await settle();
        expect(lastOf(t, 'screen:state')?['reason'], kHostBusyReason);

        await host.service.dispose();
        await session.close();
      },
    );

    test('a viewer-chooses request answers with the catalog', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();

      final published = lastOf(t, 'screen:windows');
      expect(published?['windows'], [
        {'id': '4242', 'title': 'Notepad'},
      ]);
      expect(host.service.currentState.stage, ScreenShareStage.awaitingPick);
      // No local dialog: the two ends must never both be choosing.
      expect(lastOf(t, 'screen:state')?['status'], isNot('awaiting-consent'));

      await host.service.dispose();
      await session.close();
    });

    test('the default request still asks the local user', () async {
      // Silence on the wire has to keep meaning host-picks, or an older client's
      // request would start enumerating windows it never asked to see.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();

      expect(lastOf(t, 'screen:windows'), isNull);
      expect(host.service.currentState.stage, ScreenShareStage.awaitingConsent);

      await host.service.dispose();
      await session.close();
    });

    test('a pick from the catalog starts that window', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();
      fromViewer(t, 'screen:pick', {'windowId': '4242'});
      await settle();

      expect(host.backend.startedWindows, ['4242']);
      expect(host.service.currentState.stage, ScreenShareStage.live);

      await host.service.dispose();
      await session.close();
    });

    test('a pick for a window never offered captures nothing', () async {
      // The published catalog is the ONLY bound on which window a remote peer
      // may name — there is nothing behind it.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();
      fromViewer(t, 'screen:pick', {'windowId': '9999'});
      await settle();

      expect(host.backend.startedWindows, isEmpty);
      expect(lastOf(t, 'screen:state')?['reason'], kUnknownWindowReason);

      await host.service.dispose();
      await session.close();
    });

    test('a pick with no catalog behind it captures nothing', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:pick', {'windowId': '4242'});
      await settle();

      expect(host.backend.startedWindows, isEmpty);

      await host.service.dispose();
      await session.close();
    });

    test('the catalog is spent once, so a pick cannot be replayed', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();
      fromViewer(t, 'screen:pick', {'windowId': '4242'});
      await settle();
      await host.service.stopSession('done');
      await settle();

      fromViewer(t, 'screen:pick', {'windowId': '4242'});
      await settle();

      expect(host.backend.startedWindows, ['4242']);

      await host.service.dispose();
      await session.close();
    });

    test('no shareable window is said, not silently answered', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeBackend()..windows = const [];
      final host = buildHost(session, backend: backend);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();

      expect(lastOf(t, 'screen:windows'), isNull);
      expect(lastOf(t, 'screen:state')?['reason'], kNoWindowsReason);

      await host.service.dispose();
      await session.close();
    });

    test('the switch off refuses the catalog, not just the capture', () async {
      // A list of the machine's open windows is a disclosure of its own, so it
      // answers to the same switch the capture does.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session, policy: FakePolicy(enabled: false));

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();

      expect(lastOf(t, 'screen:windows'), isNull);
      expect(lastOf(t, 'screen:state')?['status'], 'ended');

      await host.service.dispose();
      await session.close();
    });
  });

  group('consent', () {
    test('a request with no policy source fails closed', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session, withPolicy: false);

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();

      final state = lastOf(t, 'screen:state');
      expect(state?['status'], 'ended');
      expect(state?['reason'], kNoPolicyReason);
      expect(host.service.currentState.stage, ScreenShareStage.idle);

      await host.service.dispose();
      await session.close();
    });

    test('a request with the switch off is refused, not queued', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session, policy: FakePolicy(enabled: false));

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();

      expect(lastOf(t, 'screen:state')?['status'], 'ended');
      expect(lastOf(t, 'screen:state')?['reason'], kPolicyRevokedReason);
      expect(host.service.currentState.stage, ScreenShareStage.idle);

      await host.service.dispose();
      await session.close();
    });

    test(
      'picking a window with the switch off names the remedy, not a bug',
      () async {
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = buildHost(session, policy: FakePolicy(enabled: false));

        await host.service.startSession('42');
        await settle();

        // The local user is the one who can fix this, so "off" must not report
        // itself as the build being unable to see the switch — that sends them
        // hunting for a bug that isn't there.
        expect(host.service.currentState.reason, kPolicyDisabledReason);
        expect(host.backend.startedWindows, isEmpty);

        await host.service.dispose();
        await session.close();
      },
    );

    test(
      'declining a request tells the viewer and frees the session',
      () async {
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = buildHost(session);

        fromViewer(t, 'screen:request', {'projectId': 'p'});
        await settle();
        await host.service.stopSession(kConsentDeclinedReason);
        await settle();

        final ended = lastOf(t, 'screen:state');
        expect(ended?['status'], 'ended');
        expect(ended?['reason'], kConsentDeclinedReason);
        expect(ended?['viewerId'], kViewer);
        expect(host.service.currentState.stage, ScreenShareStage.idle);

        // Another device is no longer refused as busy.
        fromViewer(t, 'screen:request', {'projectId': 'p'}, kOtherViewer);
        await settle();
        expect(lastOf(t, 'screen:state')?['status'], 'awaiting-consent');
        expect(lastOf(t, 'screen:state')?['viewerId'], kOtherViewer);

        await host.service.dispose();
        await session.close();
      },
    );

    test('a request asks the local user and names no window', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();

      expect(lastOf(t, 'screen:state')?['status'], 'awaiting-consent');
      expect(host.service.currentState.stage, ScreenShareStage.awaitingConsent);
      // Consent alone must never start a capture — the window comes from local UI.
      expect(host.backend.startedWindows, isEmpty);

      await host.service.dispose();
      await session.close();
    });

    test('a viewer session never hosts', () async {
      // The stock fake transport reports relay, i.e. a project on some OTHER
      // machine. Capturing this screen for it would be the wrong machine entirely.
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();

      expect(host.service.canHost, isFalse);
      expect(t.sent, isEmpty);

      await host.service.dispose();
      await session.close();
    });
  });

  group('negotiation', () {
    test(
      'startSession offers with the DTLS fingerprint and goes live',
      () async {
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = buildHost(session);

        fromViewer(t, 'screen:request', {'projectId': 'p'});
        await settle();
        await host.service.startSession('4242');

        final offer = lastOf(t, 'screen:offer');
        expect(offer?['dtlsFingerprint'], kHostFingerprint);
        expect(offer?['sdp'], contains('a=fingerprint:$kHostFingerprint'));
        expect(offer?['width'], 1440);
        expect(offer?['height'], 900);

        final state = lastOf(t, 'screen:state');
        expect(state?['status'], 'live');
        expect(state?['windowTitle'], 'Notepad');
        expect(host.service.currentState.stage, ScreenShareStage.live);
        expect(host.injector.boundWindow, 4242);

        await host.service.dispose();
        await session.close();
      },
    );

    test('a capture that will not start is reported, not swallowed', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);
      host.backend.startError = StateError('window vanished');

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();
      await host.service.startSession('4242');

      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(lastOf(t, 'screen:state')?['status'], 'ended');
      expect(lastOf(t, 'screen:offer'), isNull);

      await host.service.dispose();
      await session.close();
    });

    test('local ICE candidates go out as screen:ice', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.backend.peer.candidates.add(
        const ScreenIceCandidate(
          candidate: 'candidate:1 1 udp',
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      );
      await settle();

      final ice = lastOf(t, 'screen:ice');
      expect(ice?['candidate'], 'candidate:1 1 udp');
      expect(ice?['sdpMLineIndex'], 0);

      await host.service.dispose();
      await session.close();
    });

    test('an answer whose fingerprint contradicts its SDP aborts', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      fromViewer(t, 'screen:answer', {
        'sdp': sdpWithFingerprint(kViewerFingerprint),
        'dtlsFingerprint': kHostFingerprint,
      });
      await settle();

      expect(host.backend.peer.acceptedAnswers, isEmpty);
      expect(host.backend.peer.disposed, isTrue);
      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(lastOf(t, 'screen:state')?['status'], 'ended');

      await host.service.dispose();
      await session.close();
    });

    test('a matching answer is accepted and flushes buffered ICE', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      // Arrives before the answer, so it has nowhere to go until one lands.
      fromViewer(t, 'screen:ice', {'candidate': 'candidate:early'});
      await settle();
      expect(host.backend.peer.addedCandidates, isEmpty);

      fromViewer(t, 'screen:answer', {
        'sdp': sdpWithFingerprint(kViewerFingerprint),
        'dtlsFingerprint': kViewerFingerprint,
      });
      await settle();

      expect(host.backend.peer.acceptedAnswers, hasLength(1));
      expect(host.backend.peer.addedCandidates.map((c) => c.candidate), [
        'candidate:early',
      ]);

      await host.service.dispose();
      await session.close();
    });

    test('a substituted media certificate aborts the session', () async {
      // The relay can read and rewrite the SDP, so the sealed answer agreeing
      // with the SDP is not enough on its own: what DTLS actually accepted has
      // to be the certificate the viewer signed for. This is the case where a
      // relay put its own peer in the middle of the media.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.backend.peer.negotiatedFingerprint = 'sha-256 99:88:77:66';

      emitAnswer(t);
      await settle();

      expect(host.backend.peer.acceptedAnswers, hasLength(1));
      expect(host.backend.peer.disposed, isTrue);
      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(
        host.service.currentState.reason,
        kViewerCertificateMismatchReason,
      );
      expect(lastOf(t, 'screen:state')?['status'], 'ended');

      await host.service.dispose();
      await session.close();
    });

    test('the negotiated certificate matching keeps the session', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      emitAnswer(t);
      await settle();
      host.backend.peer.states.add(ScreenPeerState.connected);
      await settle();

      expect(host.backend.peer.disposed, isFalse);
      expect(host.service.currentState.stage, ScreenShareStage.live);

      await host.service.dispose();
      await session.close();
    });

    test('a certificate the peer never reports does not end the session', () async {
      // Fails open deliberately: DTLS already refuses a certificate the remote
      // description did not name, and that description was checked against the
      // sealed answer. A platform that does not populate the statistic costs the
      // confirmation, not the binding.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.backend.peer.negotiatedFingerprint = null;

      emitAnswer(t);
      await settle();
      host.backend.peer.states.add(ScreenPeerState.connected);
      await settle();

      expect(host.backend.peer.disposed, isFalse);
      expect(host.service.currentState.stage, ScreenShareStage.live);

      await host.service.dispose();
      await session.close();
    });
  });

  group('input', () {
    test('datachannel events reach the injector', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.backend.peer.input.add(jsonEncode({'t': 'move', 'x': 12, 'y': 34}));
      host.backend.peer.input.add(
        jsonEncode({'t': 'down', 'x': 12, 'y': 34, 'b': 'right'}),
      );
      host.backend.peer.input.add(
        jsonEncode({'t': 'key', 'vk': 65, 'down': true}),
      );
      host.backend.peer.input.add(jsonEncode({'t': 'text', 's': 'hi'}));
      host.backend.peer.input.add('not json at all');
      host.backend.peer.input.add(jsonEncode({'t': 'move'}));
      await settle();

      expect(host.injector.pointers, hasLength(2));
      expect(host.injector.pointers.first.action, PointerAction.move);
      expect(host.injector.pointers.last.button, PointerButton.right);
      expect(host.injector.keys.single.virtualKeyCode, 65);
      expect(host.injector.texts.single, 'hi');

      await host.service.dispose();
      await session.close();
    });

    test('a press raises the target when the local user took focus', () async {
      // SendInput goes wherever the foreground is, so the injector refuses
      // everything the moment the local user clicks elsewhere. Nothing else
      // re-raises, so without this the session is view-only from that click on.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.injector.foreground = false;

      host.backend.peer.input.add(jsonEncode({'t': 'down', 'x': 5, 'y': 6}));
      await settle();

      expect(host.injector.raiseCalls, 1);
      expect(host.injector.pointers.single.action, PointerAction.down);

      // A second press with the foreground already back must not raise again.
      host.backend.peer.input.add(jsonEncode({'t': 'down', 'x': 7, 'y': 8}));
      await settle();
      expect(host.injector.raiseCalls, 1);

      await host.service.dispose();
      await session.close();
    });

    test('a move never steals the desktop back', () async {
      // A cursor drifting across the shared window must not yank focus from
      // whoever is sitting at that machine — only a press means "I am driving".
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.injector.foreground = false;

      host.backend.peer.input.add(jsonEncode({'t': 'move', 'x': 5, 'y': 6}));
      host.backend.peer.input.add(
        jsonEncode({'t': 'key', 'vk': 65, 'down': true}),
      );
      await settle();

      expect(host.injector.raiseCalls, 0);

      await host.service.dispose();
      await session.close();
    });

    test('input that arrives mid-raise replays in order behind it', () async {
      // The raise hops to a worker isolate. Letting the release through while it
      // is still in flight would have the injector refuse the release and accept
      // the press, leaving the target holding a button nothing ever lifts.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.injector.foreground = false;
      final gate = Completer<bool>();
      host.injector.pendingRaise = gate;

      host.backend.peer.input.add(jsonEncode({'t': 'down', 'x': 1, 'y': 2}));
      await settle();
      host.backend.peer.input.add(jsonEncode({'t': 'move', 'x': 3, 'y': 4}));
      host.backend.peer.input.add(jsonEncode({'t': 'up', 'x': 3, 'y': 4}));
      await settle();

      expect(host.injector.pointers, isEmpty);

      gate.complete(true);
      await settle();

      expect(host.injector.pointers.map((p) => p.action), [
        PointerAction.down,
        PointerAction.move,
        PointerAction.up,
      ]);

      await host.service.dispose();
      await session.close();
    });

    test('a refused raise is reported instead of swallowed', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.injector.foreground = false;
      host.injector.raiseSucceeds = false;

      host.backend.peer.input.add(jsonEncode({'t': 'down', 'x': 1, 'y': 2}));
      await settle();

      expect(host.injector.pointers, isEmpty);
      expect(host.service.currentState.reason, kForegroundRaiseDeniedReason);
      // Recoverable, so the session keeps its input path rather than ending.
      expect(host.service.currentState.inputActive, isTrue);
      expect(host.service.currentState.stage, ScreenShareStage.live);

      // The next press succeeds, and the warning has to go with it.
      host.injector.raiseSucceeds = true;
      host.backend.peer.input.add(jsonEncode({'t': 'down', 'x': 1, 'y': 2}));
      await settle();
      expect(host.service.currentState.reason, isNull);

      await host.service.dispose();
      await session.close();
    });

    test('input starts on the first frame size the stats poll reports', () async {
      // On Windows the track's getSettings() carries no dimensions, so the size
      // is 0x0 at offer time and only the encoder's stats know it. Input begins
      // exactly once in a session, so if it does not begin here the mouse and
      // keyboard half of the feature is dead for the whole session.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeBackend(
        peer: FakePeer(frameSize: const ScreenFrameSize(0, 0)),
      );
      final host = buildHost(session, backend: backend);

      await host.service.startSession('4242');

      expect(host.service.currentState.stage, ScreenShareStage.live);
      expect(host.service.currentState.inputActive, isFalse);
      expect(host.service.currentState.reason, kAwaitingFrameSizeReason);
      expect(host.injector.boundWindow, isNull);

      backend.peer.statsSize = const ScreenFrameSize(1440, 900);
      await host.service.checkFrameHealth();

      expect(host.service.currentState.inputActive, isTrue);
      expect(host.service.currentState.reason, isNull);
      expect(host.injector.boundWindow, 4242);
      expect(host.injector.transforms.last.frameWidth, 1440);

      await host.service.dispose();
      await session.close();
    });

    test(
      'a window with no screen origin does not read as a pending frame',
      () async {
        // Same null transform, opposite remedies: one resolves itself on the next
        // poll, the other never will. Telling the user the window is gone while
        // the first frame is still coming sends them to restart a working session.
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = buildHost(session, windowOrigin: (_) => null);

        await host.service.startSession('4242');

        expect(host.service.currentState.inputActive, isFalse);
        expect(host.service.currentState.reason, kWindowOffScreenReason);
        expect(host.injector.boundWindow, isNull);

        await host.service.dispose();
        await session.close();
      },
    );

    test(
      'an elevated target degrades to view-only rather than ending',
      () async {
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = buildHost(session);
        host.injector.beginError = const InputInjectionException(
          InputInjectionFailure.targetElevated,
          'That app runs as administrator.',
        );

        await host.service.startSession('4242');

        expect(host.service.currentState.stage, ScreenShareStage.live);
        expect(host.service.currentState.inputActive, isFalse);
        expect(
          host.service.currentState.reason,
          'That app runs as administrator.',
        );

        await host.service.dispose();
        await session.close();
      },
    );
  });

  group('session end', () {
    test('revoking screen control tears the peer connection down', () async {
      // The datachannel bypasses the bridge entirely, so no frame gate can stop
      // remote input. Teardown is the only enforcement there is.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      expect(host.injector.boundWindow, 4242);

      host.policy.set(false);
      await settle();

      expect(host.backend.peer.disposed, isTrue);
      expect(host.injector.endSessionCalls, 1);
      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(host.service.currentState.reason, kPolicyRevokedReason);
      expect(lastOf(t, 'screen:stop')?['reason'], kPolicyRevokedReason);
      expect(lastOf(t, 'screen:state')?['status'], 'ended');

      await host.policy.close();
      await host.service.dispose();
      await session.close();
    });

    test('input sent after revocation never reaches the injector', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.policy.set(false);
      // Queued in the same turn as the revocation, before the teardown has had a
      // chance to await anything. That instant is the whole risk: the peer object
      // still exists and the datachannel is still open.
      host.backend.peer.input.add(jsonEncode({'t': 'move', 'x': 1, 'y': 2}));
      host.backend.peer.input.add(
        jsonEncode({'t': 'key', 'vk': 65, 'down': true}),
      );
      await settle();

      expect(host.injector.pointers, isEmpty);
      expect(host.injector.keys, isEmpty);
      expect(host.backend.peer.disposed, isTrue);

      await host.policy.close();
      await host.service.dispose();
      await session.close();
    });

    test(
      'a minimised window is a stated fault, not a black rectangle',
      () async {
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = await liveHost(session, t);

        host.backend.peer.statsSize = const ScreenFrameSize(1, 1);
        await host.service.checkFrameHealth();

        expect(host.service.currentState.stage, ScreenShareStage.failed);
        expect(host.service.currentState.reason, kMinimisedReason);
        expect(host.backend.peer.disposed, isTrue);
        expect(lastOf(t, 'screen:state')?['reason'], kMinimisedReason);

        await host.service.dispose();
        await session.close();
      },
    );

    test('a minimised window is offered, and says it will be restored', () async {
      // The whole point of viewer-side picking is that nobody is at the machine
      // — so the window they want is very often the one they left minimised.
      // Dropping those from the catalog put the feature's own use case out of
      // reach.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final backend = FakeBackend();
      backend.windows = const [
        ScreenWindow(id: '4242', title: 'Notepad'),
        ScreenWindow(id: '77', title: 'Editor', minimised: true),
      ];
      final host = buildHost(session, backend: backend);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();

      final published = lastOf(t, 'screen:windows')?['windows'] as List?;
      expect(published, hasLength(2));
      expect(published?[0]['minimised'], isNull);
      expect(published?[1]['id'], '77');
      expect(published?[1]['minimised'], isTrue);

      await host.service.dispose();
      await session.close();
    });

    test(
      'the target is brought to the front before the capture is attempted',
      () async {
        // Ordering is the whole point. libwebrtc calls `FocusOnSelectedSource()`
        // for every window source and fails `Start()` when it returns false, so
        // preparing after `startShare` would be preparing after the only moment
        // it could have mattered. '4242' is an ordinary open window: preparation
        // is NOT conditional on the target being minimised, which is the bug this
        // pins — gating it on minimised left every already-open window uncaptured.
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final prepared = <int>[];
        final backend = FakeBackend();
        final host = buildHost(
          session,
          backend: backend,
          preparedWindows: prepared,
        );

        await host.service.startSession('4242');

        expect(prepared, [4242]);
        expect(backend.startedWindows, ['4242']);

        await host.service.dispose();
        await session.close();
      },
    );

    test(
      'a window that will not come to the front fails before any capture',
      () async {
        // Knowable up front, so it must be said up front: the frameless timeout
        // would reach the same verdict twelve seconds later and blame the wrong
        // thing while doing it.
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final backend = FakeBackend();
        final host = buildHost(
          session,
          backend: backend,
          prepareWindow: (_) async => false,
        );

        fromViewer(t, 'screen:request', {'projectId': 'p'});
        await settle();
        await host.service.startSession('4242');

        expect(host.service.currentState.stage, ScreenShareStage.failed);
        expect(host.service.currentState.reason, kCouldNotFocusReason);
        expect(backend.startedWindows, isEmpty);
        expect(lastOf(t, 'screen:state')?['reason'], kCouldNotFocusReason);

        await host.service.dispose();
        await session.close();
      },
    );

    test(
      'a capture that never produces a frame ends instead of spinning',
      () async {
        // The failure this exists for: Windows enumerates a window it cannot
        // capture, the peer connects, and the capturer silently delivers nothing
        // — no error, no track end. Without this the viewer waits on a first
        // frame forever, which is indistinguishable from a slow one.
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = await liveHost(session, t);
        host.backend.peer.states.add(ScreenPeerState.connected);
        await settle();

        for (var i = 0; i < kMaxFramelessPolls - 1; i++) {
          await host.service.checkFrameHealth();
          expect(host.service.currentState.stage, ScreenShareStage.live);
        }
        await host.service.checkFrameHealth();

        expect(host.service.currentState.stage, ScreenShareStage.failed);
        expect(host.service.currentState.reason, kNoFramesReason);
        expect(host.backend.peer.disposed, isTrue);
        expect(lastOf(t, 'screen:state')?['reason'], kNoFramesReason);

        await host.service.dispose();
        await session.close();
      },
    );

    test('frameless polls before a viewer connects are not counted', () async {
      // A session armed from this machine sits at `live` with nothing to send
      // frames to. Ending that as a failed capture would kill every share that
      // waits more than twelve seconds for its viewer.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      for (var i = 0; i < kMaxFramelessPolls * 2; i++) {
        await host.service.checkFrameHealth();
      }

      expect(host.service.currentState.stage, ScreenShareStage.live);
      expect(host.service.currentState.reason, isNot(kNoFramesReason));

      await host.service.dispose();
      await session.close();
    });

    test('a frame arriving clears the frameless run', () async {
      // The count must be consecutive: a session that stalls briefly, recovers,
      // and stalls again is a working session, and summing those runs would end
      // it on a total that never represents a dead capture.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);
      host.backend.peer.states.add(ScreenPeerState.connected);
      await settle();

      for (var i = 0; i < kMaxFramelessPolls - 1; i++) {
        await host.service.checkFrameHealth();
      }
      host.backend.peer.statsSize = const ScreenFrameSize(1440, 900);
      await host.service.checkFrameHealth();
      host.backend.peer.statsSize = null;
      for (var i = 0; i < kMaxFramelessPolls - 1; i++) {
        await host.service.checkFrameHealth();
      }

      expect(host.service.currentState.stage, ScreenShareStage.live);

      await host.service.dispose();
      await session.close();
    });

    test('a resize re-points the coordinate seam', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.backend.peer.statsSize = const ScreenFrameSize(1200, 700);
      await host.service.checkFrameHealth();

      expect(
        host.service.currentState.frameSize,
        const ScreenFrameSize(1200, 700),
      );
      expect(host.injector.transforms.last.frameWidth, 1200);
      expect(lastOf(t, 'screen:state')?['width'], 1200);

      await host.service.dispose();
      await session.close();
    });

    test('the window closing ends the session', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.backend.peer.ended.add(null);
      await settle();

      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(host.injector.endSessionCalls, 1);
      expect(lastOf(t, 'screen:state')?['status'], 'ended');

      await host.service.dispose();
      await session.close();
    });

    test('the peer connection failing ends the session', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.backend.peer.states.add(ScreenPeerState.failed);
      await settle();

      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(host.backend.peer.disposed, isTrue);

      await host.service.dispose();
      await session.close();
    });

    test(
      'an ICE disconnect is published rather than ending or hiding',
      () async {
        // Silence here is what leaves the viewer rendering the last frame it
        // received and calling that live.
        final t = LocalFakeAgentTransport();
        final session = await newSession(t);
        final host = await liveHost(session, t);

        host.backend.peer.states.add(ScreenPeerState.disconnected);
        await settle();

        expect(host.service.currentState.stage, ScreenShareStage.interrupted);
        expect(host.backend.peer.disposed, isFalse);
        final interrupted = lastOf(t, 'screen:state');
        expect(interrupted?['status'], 'interrupted');
        expect(interrupted?['reason'], kPeerInterruptedReason);

        host.backend.peer.states.add(ScreenPeerState.connected);
        await settle();

        expect(host.service.currentState.stage, ScreenShareStage.live);
        expect(host.service.currentState.reason, isNull);
        expect(lastOf(t, 'screen:state')?['status'], 'live');

        await host.service.dispose();
        await session.close();
      },
    );

    test('a live stage does not claim anyone is watching', () async {
      // The host reaches `live` the moment it has an offer, which is also the
      // state a session sits in forever when it was armed from the machine that
      // owns the window and no device ever answers. Reporting that as sharing
      // is the difference between "nothing is leaving this machine" and a user
      // believing a window is on someone's screen.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      expect(host.service.currentState.stage, ScreenShareStage.live);
      expect(host.service.currentState.viewerConnected, isFalse);

      host.backend.peer.states.add(ScreenPeerState.connected);
      await settle();

      expect(host.service.currentState.viewerConnected, isTrue);

      // A dropped path is a viewer that exists and is expected back, so the
      // never-connected wording must not come back with the interruption.
      host.backend.peer.states.add(ScreenPeerState.disconnected);
      await settle();

      expect(host.service.currentState.stage, ScreenShareStage.interrupted);
      expect(host.service.currentState.viewerConnected, isTrue);

      await host.service.dispose();
      await session.close();
    });

    test('a disconnect that never recovers ends the session', () async {
      // Without this the target window stays held in the foreground on a path
      // that is not coming back.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(
        session,
        t,
        peerRecoveryGrace: const Duration(milliseconds: 5),
      );

      host.backend.peer.states.add(ScreenPeerState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(host.service.currentState.reason, kPeerRecoveryTimedOutReason);
      expect(host.backend.peer.disposed, isTrue);
      expect(host.injector.endSessionCalls, 1);
      expect(lastOf(t, 'screen:state')?['status'], 'ended');

      await host.service.dispose();
      await session.close();
    });

    test('a re-request from the bound viewer starts over', () async {
      // The viewer drops its peer before every request, so re-advertising the
      // old session would leave it waiting on an offer that never comes.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      host.backend.peer.states.add(ScreenPeerState.disconnected);
      await settle();
      t.clearSent();
      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();
      await settle();

      expect(host.backend.peer.disposed, isTrue);
      expect(host.injector.endSessionCalls, 1);
      expect(host.service.currentState.stage, ScreenShareStage.awaitingConsent);
      expect(t.sent.where((m) => m['type'] == 'screen:stop'), isEmpty);
      final state = lastOf(t, 'screen:state');
      expect(state?['status'], 'awaiting-consent');
      expect(state?['viewerId'], kViewer);

      await host.service.dispose();
      await session.close();
    });

    test('a stop while the capture is starting leaves nothing live', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final raised = Completer<bool>();
      final host = buildHost(session, prepareWindow: (_) => raised.future);

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();
      final starting = host.service.startSession('4242');
      await settle();
      expect(host.service.currentState.stage, ScreenShareStage.starting);

      fromViewer(t, 'screen:stop', {'reason': 'viewer-gone'});
      await settle();
      raised.complete(true);
      await starting;
      await settle();

      expect(host.backend.startedWindows, isEmpty);
      expect(host.injector.boundWindow, isNull);
      expect(host.service.currentState.stage, ScreenShareStage.idle);
      expect(t.sent.where((m) => m['type'] == 'screen:offer'), isEmpty);

      // Nothing is left armed for the next device to adopt.
      t.clearSent();
      fromViewer(t, 'screen:request', {'projectId': 'p'}, kOtherViewer);
      await settle();
      expect(t.sent.map((m) => m['type']), ['screen:state']);
      expect(lastOf(t, 'screen:state')?['status'], 'awaiting-consent');

      await host.service.dispose();
      await session.close();
    });

    test('a remote stop ends the session without answering back', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      fromViewer(t, 'screen:stop', {'reason': 'viewer closed the tab'});
      await settle();

      expect(host.backend.peer.disposed, isTrue);
      expect(host.service.currentState.stage, ScreenShareStage.idle);
      expect(t.sent.where((m) => m['type'] == 'screen:stop'), isEmpty);

      await host.service.dispose();
      await session.close();
    });
  });

  group('viewer addressing', () {
    test('every frame the host sends names the viewer that asked', () async {
      // The bridge drops an unaddressed host frame rather than broadcast it, so
      // one missing viewerId is a silently dead session.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      fromViewer(t, 'screen:request', {'projectId': 'p', 'chooser': 'viewer'});
      await settle();
      fromViewer(t, 'screen:pick', {'windowId': '4242'});
      await settle();
      host.backend.peer.candidates.add(
        const ScreenIceCandidate(candidate: 'candidate:1 1 udp'),
      );
      await settle();
      await host.service.stopSession('done');
      await settle();

      final types = t.sent.map((m) => m['type']).toSet();
      expect(
        types,
        containsAll([
          'screen:windows',
          'screen:offer',
          'screen:ice',
          'screen:state',
          'screen:stop',
        ]),
      );
      for (final frame in t.sent) {
        expect(frame['viewerId'], kViewer, reason: '${frame['type']}');
      }

      await host.service.dispose();
      await session.close();
    });

    test('a second viewer is refused to its face and cannot steer', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      fromViewer(t, 'screen:request', {'projectId': 'p'}, kOtherViewer);
      await settle();

      final refusal = lastOf(t, 'screen:state');
      expect(refusal?['status'], 'ended');
      expect(refusal?['reason'], kHostBusyReason);
      expect(refusal?['viewerId'], kOtherViewer);
      expect(t.sent.where((m) => m['viewerId'] == kViewer), isEmpty);

      fromViewer(t, 'screen:answer', {
        'sdp': sdpWithFingerprint(kViewerFingerprint),
        'dtlsFingerprint': kViewerFingerprint,
      }, kOtherViewer);
      fromViewer(t, 'screen:stop', {'reason': 'hijack'}, kOtherViewer);
      await settle();

      expect(host.backend.peer.acceptedAnswers, isEmpty);
      expect(host.backend.peer.disposed, isFalse);
      expect(host.service.currentState.stage, ScreenShareStage.live);

      await host.service.dispose();
      await session.close();
    });

    test('the bridge reporting the viewer gone ends the session', () async {
      // Without this the capture runs on until ICE gives up — tens of seconds
      // of a window streaming to nobody.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      fromViewer(t, 'screen:stop', {'reason': 'viewer-gone'});
      await settle();

      expect(host.backend.peer.disposed, isTrue);
      expect(host.injector.endSessionCalls, 1);
      expect(host.service.currentState.stage, ScreenShareStage.idle);
      expect(t.sent, isEmpty);

      // The session is free again, so the next device to ask is not busy-ed.
      fromViewer(t, 'screen:request', {'projectId': 'p'}, kOtherViewer);
      await settle();
      expect(lastOf(t, 'screen:state')?['status'], 'awaiting-consent');
      expect(lastOf(t, 'screen:state')?['viewerId'], kOtherViewer);

      await host.service.dispose();
      await session.close();
    });

    test('a request with no viewer id is ignored', () async {
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      t.emit('screen:request', {'projectId': 'p'});
      await settle();

      expect(host.backend.peer.disposed, isFalse);
      expect(host.service.currentState.stage, ScreenShareStage.live);
      expect(t.sent, isEmpty);

      await host.service.dispose();
      await session.close();
    });

    test('the bridge revoking sharing ends the session and says why', () async {
      // An unaddressed stop can only be the bridge's own: every viewer frame
      // arrives stamped. For remote access it is the host's only notice.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = await liveHost(session, t);

      t.emit('screen:stop', {'reason': 'remote access turned off'});
      await settle();

      expect(host.backend.peer.disposed, isTrue);
      expect(host.injector.endSessionCalls, 1);
      expect(host.service.currentState.stage, ScreenShareStage.failed);
      expect(host.service.currentState.reason, kRemoteAccessRevokedReason);
      // The bridge has already told the viewer.
      expect(t.sent, isEmpty);

      await host.service.dispose();
      await session.close();
    });

    test('a session armed here is handed to the first viewer to ask', () async {
      // The offer and candidates of a share started before any device asked
      // had nobody to go to. The viewer that adopts it needs all of them.
      final t = LocalFakeAgentTransport();
      final session = await newSession(t);
      final host = buildHost(session);

      await host.service.startSession('4242');
      host.backend.peer.candidates.add(
        const ScreenIceCandidate(candidate: 'candidate:early'),
      );
      await settle();
      expect(t.sent, isEmpty);

      fromViewer(t, 'screen:request', {'projectId': 'p'});
      await settle();

      expect(t.sent.map((m) => m['type']), [
        'screen:offer',
        'screen:ice',
        'screen:state',
      ]);
      expect(lastOf(t, 'screen:state')?['status'], 'live');
      for (final frame in t.sent) {
        expect(frame['viewerId'], kViewer);
      }

      await host.service.dispose();
      await session.close();
    });
  });

  group('fingerprint helpers', () {
    test('parses the fingerprint out of an SDP', () {
      expect(
        parseDtlsFingerprint(sdpWithFingerprint(kHostFingerprint)),
        kHostFingerprint,
      );
      expect(parseDtlsFingerprint('v=0\r\nm=video 9\r\n'), isNull);
    });

    test('compares case- and whitespace-insensitively', () {
      expect(dtlsFingerprintsMatch('sha-256 AA:BB', 'sha-256  aa:bb '), isTrue);
      expect(dtlsFingerprintsMatch('sha-256 AA:BB', 'sha-256 AA:BC'), isFalse);
    });
  });
}
