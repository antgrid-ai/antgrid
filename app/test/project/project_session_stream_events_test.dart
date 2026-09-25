// Pins the focus re-declaration hook wired in project_session.dart's
// StreamTransport branch: a project's native stream re-binding must
// re-declare BOTH halves of focus — client:focus-state (paused) via
// MessageRouter.resyncFocusState, and the named session via
// SessionsService.resyncFocus — and a stream drop must fail pending replies
// immediately rather than waiting out their own timers. It also pins
// _projectStreamLost: a FileService's in-flight git request must be re-issued
// on the reopen that follows a drop (whether the drop was this project's own
// stream ending, or the whole machine session going down), but never on the
// very first bind. MachineSession's own bind/reopen mechanics (readiness,
// backoff, caps) are pinned separately in antgrid_relay_client's
// machine_session_project_stream_test.dart; this suite only exercises
// ProjectSession's reaction to the resulting projectStreamEvents.
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
  _FakeHandshaker([this._outcomes = const [true]]);

  /// One outcome per `perform()` call, in order; the last entry repeats for
  /// any call past the end of the list.
  final List<bool> _outcomes;
  int _calls = 0;

  @override
  Future<bool> perform() async {
    final ok = _outcomes[_calls.clamp(0, _outcomes.length - 1)];
    _calls++;
    return ok;
  }

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
  Future<PeerSendOutcome> sendFrame(String kind, Uint8List payload) async =>
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

  /// Counts closes without closing the controllers: the one [MachineSession]
  /// under test re-handshakes over this same link after a failed attempt
  /// closes it, which is how the production wrapper (`LeasedPeerLink`)
  /// redials underneath a session.
  int closes = 0;

  @override
  Future<void> close() async {
    closes++;
  }

  /// Simulates the payload socket itself dying, distinct from any single
  /// project's own stream ending — this is what MachineSession's own
  /// liveness/close path reacts to.
  void simulateSocketClosed() => _states.add(PeerLinkState.closed);

  /// Injects a plaintext control-plane record. `kind` defaults to the bare
  /// message plane; pass [kPeerFrameSession] for a session-plane message
  /// (e.g. `session-takeover`).
  void inject(Map<String, dynamic> message, {String kind = kPeerFrameMessage}) =>
      _messages.add(
        IncomingPeerFrame(
          kind: kind,
          payload: Uint8List.fromList(utf8.encode(jsonEncode(message))),
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

/// Advertises 'p1' ready, opens its native stream, and answers the bind's
/// first record — the same readiness -> open -> stream-ready round trip a
/// real bridge drives. Returns the bound, connected transport.
Future<StreamTransport> _bindProject(
  _FakeLink link,
  MachineSession machineSession,
) async {
  link.inject({'type': 'stream-ready', 'projectId': 'p1'});
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final bindFuture = machineSession.openProject('p1', {
    'type': 'project:start',
    'projectId': 'p1',
  });
  await Future<void>.delayed(const Duration(milliseconds: 20));
  link.openedStreams.last.injectStreamReady('p1');
  final transport = await bindFuture;
  await transport.connect();
  return transport;
}

void main() {
  group('ProjectSession reacts to projectStreamEvents', () {
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

    test(
      'R1: a project-stream reopen after open:false calls '
      'reissueAfterStreamReset on every checkout FileService, resending its '
      'in-flight diff exactly once',
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
        final transport = await _bindProject(link, machineSession);

        final cache = await CachedSessionsStore.open();
        final session = ProjectSession(
          projectId: 'p1',
          transport: transport,
          mode: ProjectSessionMode.relay,
          cachedSessionsStore: cache,
          onClose: transport.dispose,
        );
        addTearDown(session.close);

        final firstStream = link.openedStreams.single;
        session.fileService.requestDiff('lib/main.dart');
        await Future<void>.delayed(Duration.zero);
        expect(
          firstStream.countSent('git:diff'),
          1,
          reason: 'the organic send, before anything ever drops',
        );

        // The bridge's own FIN, mirroring the drop the earlier test exercises.
        firstStream.end();
        await Future<void>.delayed(Duration.zero);

        // The stream's own backoff-driven reopen — see
        // kProjectStreamReopenInitialBackoff — the session itself never went
        // down here.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        link.inject({'type': 'stream-ready', 'projectId': 'p1'});
        for (var i = 0; i < 50 && link.openedStreams.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          link.openedStreams.length,
          2,
          reason: 'the reopen must open a fresh native stream',
        );
        final secondStream = link.openedStreams[1];
        secondStream.injectStreamReady('p1');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          secondStream.countSent('git:diff'),
          1,
          reason: 'the still-pending diff must be re-sent exactly once on '
              'the fresh stream',
        );
      },
    );

    test(
      'R2: the first open observed after construction re-issues nothing — a '
      'diff requested right after binding is sent once, not reissued',
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
        final transport = await _bindProject(link, machineSession);

        final cache = await CachedSessionsStore.open();
        final session = ProjectSession(
          projectId: 'p1',
          transport: transport,
          mode: ProjectSessionMode.relay,
          cachedSessionsStore: cache,
          onClose: transport.dispose,
        );
        addTearDown(session.close);

        final firstStream = link.openedStreams.single;
        session.fileService.requestDiff('lib/main.dart');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          firstStream.countSent('git:diff'),
          1,
          reason: 'nothing has dropped yet, so there is nothing to reissue — '
              'a wrongly-initialized flag would double-send here',
        );
      },
    );

    test(
      'R3: a reopen after the whole machine session goes down (not just '
      "this project's own stream) still re-issues the in-flight diff",
      () async {
        final link = _FakeLink();
        // Establishes, then fails one re-attempt (fires sessionDownEvents),
        // then succeeds on the reattempt after that.
        final machineSession = MachineSession(
          relay: link,
          machineDeviceId: 'machine-1',
          handshaker: _FakeHandshaker([true, false, true]),
          projectStartMessageBuilder: (projectId) => {
            'type': 'project:start',
            'projectId': projectId,
          },
        );
        machineSession.start();
        await machineSession.ensureEstablished();
        addTearDown(machineSession.dispose);
        final transport = await _bindProject(link, machineSession);

        final cache = await CachedSessionsStore.open();
        final session = ProjectSession(
          projectId: 'p1',
          transport: transport,
          mode: ProjectSessionMode.relay,
          cachedSessionsStore: cache,
          onClose: transport.dispose,
        );
        addTearDown(session.close);

        final firstStream = link.openedStreams.single;
        session.fileService.requestDiff('lib/main.dart');
        await Future<void>.delayed(Duration.zero);
        expect(firstStream.countSent('git:diff'), 1);

        // The socket itself dies — the whole session, not this project's own
        // stream, is what goes down first.
        link.simulateSocketClosed();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // A re-attempt that fails: this is what fires sessionDownEvents.
        await expectLater(
          machineSession.ensureEstablished(),
          throwsA(isA<HandshakeException>()),
        );

        // A later re-attempt succeeds; every live project stream reopens at
        // once, no backoff — see MachineSession's re-establish handling.
        await machineSession.ensureEstablished();
        link.inject({'type': 'stream-ready', 'projectId': 'p1'});
        for (var i = 0; i < 50 && link.openedStreams.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          link.openedStreams.length,
          2,
          reason: 'the fresh establishment must reopen the project stream',
        );
        final secondStream = link.openedStreams[1];
        secondStream.injectStreamReady('p1');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          secondStream.countSent('git:diff'),
          1,
          reason: 'sessionDownEvents must mark the project lost too, so the '
              "reopen re-issues even though it wasn't this stream's own FIN "
              'that reported the drop',
        );
      },
    );
  });
}
