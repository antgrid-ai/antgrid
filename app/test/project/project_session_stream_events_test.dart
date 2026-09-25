// Pins the focus re-declaration hook wired in project_session.dart's
// StreamTransport branch: a project's native stream re-binding (Stage A A4)
// must re-declare BOTH halves of focus — client:focus-state (paused) via
// MessageRouter.resyncFocusState, and the named session via
// SessionsService.resyncFocus — and a stream drop must fail pending replies
// immediately rather than waiting out their own timers. MachineSession's own
// bind/reopen mechanics (readiness, backoff, caps) are pinned separately in
// antgrid_relay_client's machine_session_project_stream_test.dart; this suite
// only exercises ProjectSession's reaction to the resulting
// projectStreamEvents.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/pending_reply.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/prefs_test_mock.dart';

class _FakeHandshaker implements SessionHandshaker {
  @override
  Future<bool> perform() async => true;
  @override
  void abort() {}
}

/// A minimal [PeerLink] + [MultiStreamPeerLink] double: enough to establish a
/// [MachineSession] and open native project streams over it.
class _FakeLink implements PeerLink, MultiStreamPeerLink {
  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();

  /// Every native project stream opened, in call order — a reopen appends a
  /// SECOND entry rather than replacing the first.
  final openedStreams = <_FakeProjectStream>[];

  @override
  bool get isDispatchAllowed => true;
  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  PeerLinkDiagnostic? get netTap => null;

  @override
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async =>
      PeerSendOutcome.accepted;

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
  }) async {
    final stream = _FakeProjectStream(open);
    openedStreams.add(stream);
    return stream;
  }

  @override
  Future<void> close() async {
    await _messages.close();
    await _states.close();
  }

  /// Injects a control-plane message, plaintext, as MachineSession's own
  /// outbound traffic is since Stage B.
  void inject(Map<String, dynamic> message) => _messages.add(
    IncomingPeerFrame(
      channel: 'control',
      payload: Uint8List.fromList(utf8.encode(jsonEncode({'m': message}))),
    ),
  );
}

/// One project's native stream, the bridge side.
class _FakeProjectStream implements PeerStream {
  _FakeProjectStream(this.open);

  final StreamOpen open;
  final _records = StreamController<Uint8List>.broadcast();
  final sent = <Map<String, dynamic>>[];
  bool _ended = false;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    sent.add(jsonDecode(utf8.decode(record)) as Map<String, dynamic>);
    return PeerSendOutcome.accepted;
  }

  // The bridge answers an app FIN or reset by ending its own half, which is
  // what lets a disposed transport release its slot.
  @override
  Future<void> reset() async => end();
  @override
  Future<void> finish() async => end();

  void injectStreamReady(String projectId) => _injectJson({
    'type': 'stream-ready',
    'projectId': projectId,
  });

  void _injectJson(Map<String, dynamic> json) {
    if (!_ended && !_records.isClosed) {
      _records.add(Uint8List.fromList(utf8.encode(jsonEncode(json))));
    }
  }

  /// Ends the bridge's send half — the stream's OWN end, which is what
  /// drives StreamTransport's reopen (never our own reset/finish).
  void end() {
    if (_ended) return;
    _ended = true;
    unawaited(_records.close());
  }

  int countSent(String type) => sent.where((m) => m['type'] == type).length;
}

void main() {
  group('ProjectSession reacts to projectStreamEvents (Stage A A4)', () {
    setUp(() {
      useInMemoryPrefs();
    });

    test(
      'a stream drop fails pending replies immediately, and the reopened '
      'stream re-declares both focus-state and the focused session',
      () async {
        final link = _FakeLink();
        final machineSession = MachineSession(
          relay: link,
          machineDeviceId: 'machine-1',
          handshaker: _FakeHandshaker(),
          projectStartMessageBuilder: (projectId) => {
            'type': 'project:start',
            'projectId': projectId,
          },
        );
        machineSession.start();
        await machineSession.ensureEstablished();
        addTearDown(machineSession.dispose);

        link.inject({'type': 'stream-ready', 'projectId': 'p1'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final bindFuture = machineSession.openProject('p1', {
          'type': 'project:start',
          'projectId': 'p1',
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        link.openedStreams.single.injectStreamReady('p1');
        final transport = await bindFuture;
        await transport.connect();

        final cache = await CachedSessionsStore.open();
        final session = ProjectSession(
          projectId: 'p1',
          transport: transport,
          mode: ProjectSessionMode.relay,
          cachedSessionsStore: cache,
          onClose: transport.dispose,
        );
        addTearDown(session.close);

        // Name a focused session so resyncFocus has something to restate.
        session.sessionsService.focus('sess-1');
        await Future<void>.delayed(Duration.zero);

        final firstStream = link.openedStreams.single;
        expect(
          firstStream.countSent('client:focus-state'),
          greaterThanOrEqualTo(1),
          reason: 'FileService declares focus-state on construction',
        );
        expect(
          firstStream.countSent('session:focus'),
          1,
          reason: 'the explicit focus() call above',
        );

        // While the stream is up, a tracked reply waits normally.
        final pendingWhileUp = session.newPending<int>(
          timeout: const Duration(seconds: 5),
        );
        pendingWhileUp.complete(1);
        expect(await pendingWhileUp.future, 1);

        // The bridge's own FIN — never our reset()/finish() — is what a real
        // stream drop looks like.
        firstStream.end();
        await Future<void>.delayed(Duration.zero);

        final pendingWhileDown = session.newPending<int>(
          timeout: const Duration(seconds: 5),
        );
        await expectLater(
          pendingWhileDown.future,
          throwsA(isA<SessionDownException>()),
          reason:
              'sessionDownEvents/projectStreamEvents(open:false) must mark '
              'the session down at once, not after the reply times out',
        );

        // The dropped stream reopens on its own with backoff — see
        // kProjectStreamReopenInitialBackoff. Once it re-asks the control
        // plane, answer readiness and the fresh native stream's first record.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        link.inject({'type': 'stream-ready', 'projectId': 'p1'});
        String? secondStreamReady;
        for (var i = 0; i < 50; i++) {
          if (link.openedStreams.length > 1) {
            secondStreamReady = 'opened';
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          secondStreamReady,
          isNotNull,
          reason: 'the reopen must open a fresh native stream',
        );
        final secondStream = link.openedStreams[1];
        secondStream.injectStreamReady('p1');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          secondStream.countSent('client:focus-state'),
          greaterThanOrEqualTo(1),
          reason:
              'resyncFocusState must re-declare the pause flag on the fresh '
              'stream — the agent resets appFocusPaused per connection',
        );
        expect(
          secondStream.countSent('session:focus'),
          1,
          reason:
              'resyncFocus must re-declare the named session on the fresh '
              'stream, or the bridge re-arms read tracking with no name and '
              'paints an unread dot on the session the user is looking at',
        );

        // Marked back up: a tracked reply now resolves normally again.
        final pendingAfterReopen = session.newPending<int>(
          timeout: const Duration(seconds: 5),
        );
        pendingAfterReopen.complete(2);
        expect(await pendingAfterReopen.future, 2);
      },
    );
  });
}
