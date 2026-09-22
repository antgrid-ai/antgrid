import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:iroh_quic/src/rust/frb_generated.dart' show RustLib;

/// App role of the cross-binding interop gate, driven by
/// `bridge/scripts/iroh-interop-smoke.ts`. Every layer below the fixture
/// authorization callback is production code: `NativeEndpointOwner` dials over
/// `iroh_quic`, and unchanged `MachineSession`/`AppSessionHandshaker` carry E2E
/// and project traffic. The peer is a real `NativeHostConnection` host binding
/// `@number0/iroh`, which is the boundary this gate exists to cross.

class _MemoryKeys implements EndpointKeyStore {
  Uint8List? _value;
  @override
  Future<Uint8List?> read(String enrollmentId) async =>
      _value == null ? null : Uint8List.fromList(_value!);
  @override
  Future<void> write(String enrollmentId, Uint8List secret) async {
    _value = Uint8List.fromList(secret);
  }

  @override
  Future<void> delete(String enrollmentId) async {
    _value?.fillRange(0, _value!.length, 0);
    _value = null;
  }
}

String _uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
      '-${h.substring(16, 20)}-${h.substring(20)}';
}

Map<String, dynamic> _message(String type, Map<String, dynamic> fields) => {
  'type': type,
  'id': _uuid(),
  'timestamp': DateTime.now().millisecondsSinceEpoch,
  ...fields,
};

void _emit(Map<String, dynamic> value) => stdout.writeln(jsonEncode(value));

/// Buffers one project stream and acknowledges terminal frames, which the
/// Flutter `TerminalService` owns in the product and no package layer does.
class _Inbox {
  _Inbox(this._session, this._streamId) {
    _sub = _session.streamFor(_streamId).messages.listen((event) {
      final json = event.json;
      if (json['type'] == 'terminal:frame') {
        _session
            .sendOnStream(
              _streamId,
              _message('terminal:ack', {
                'terminalId': json['terminalId'],
                'runId': json['runId'],
                'attachmentId': json['attachmentId'],
                'sequence': json['sequence'],
                if (json['checkoutId'] != null)
                  'checkoutId': json['checkoutId'],
              }),
              'control',
            )
            .ignore();
      }
      _buffered.add(json);
      _drain();
    });
  }

  final MachineSession _session;
  final String _streamId;
  late final StreamSubscription<InboundMessage> _sub;
  final _buffered = <Map<String, dynamic>>[];
  final _waiters =
      <
        (bool Function(Map<String, dynamic>), Completer<Map<String, dynamic>>)
      >[];

  void _drain() {
    for (final waiter in List.of(_waiters)) {
      final index = _buffered.indexWhere(waiter.$1);
      if (index < 0) continue;
      _waiters.remove(waiter);
      waiter.$2.complete(_buffered.removeAt(index));
    }
  }

  Future<Map<String, dynamic>> waitFor(
    bool Function(Map<String, dynamic>) predicate, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final completer = Completer<Map<String, dynamic>>();
    final waiter = (predicate, completer);
    _waiters.add(waiter);
    _drain();
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException('No message matched on stream $_streamId');
      },
    );
  }

  Future<void> send(Map<String, dynamic> message) =>
      _session.sendOnStream(_streamId, message, 'control');

  Future<void> close() => _sub.cancel();
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError('Usage: interop_app.dart [native-library-path]');
  }
  final libraryPath = args.isEmpty ? null : args.single;
  final crypto = CryptoService();
  final (seed, publicKey) = await crypto.generateEd25519KeyPair();
  final keyStore = _MemoryKeys();
  final client = await NativeEndpointOwner.create(
    enrollmentId: 'interop-app',
    keyStore: keyStore,
    approvedRelays: const [],
    initializeNative: () => iroh.Iroh.init(libraryPath: libraryPath),
  );
  MachineSession? session;
  PeerLink? link;
  final inboxes = <_Inbox>[];
  try {
    _emit({
      'endpointId': client.endpoint.id.toHex(),
      'publicKey': base64Encode(publicKey),
    });
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final config = jsonDecode(line) as Map<String, dynamic>;
    final machineId = config['machineId'] as String;
    final appId = config['appId'] as String;

    Future<(PeerLink, MachineSession, Future<void>)> establish() async {
      final active = link = await client.dial(
        endpointId: config['endpointId'] as String,
        // Transport address only, and scoped per machine exactly as
        // `PeerRuntime` dials. The handshake below binds the bare `appId`, which
        // is what the E2E transcript and the host's identity lookup are keyed by.
        authorized: () => true,
        ipAddresses: (config['addresses'] as List).cast<String>(),
      );
      final closed = active.payloadStateStream
          .firstWhere((state) => state == PeerLinkState.closed)
          .then((_) {});
      // Nothing awaits this until the very end; without a listener now the
      // close that arrives mid-run would surface as an unhandled error.
      closed.ignore();

      final live = session = MachineSession(
        relay: active,
        machineDeviceId: machineId,
        handshaker: AppSessionHandshaker(
          relay: active,
          crypto: crypto,
          machineDeviceId: machineId,
          phoneDeviceId: appId,
          agentEd25519PubB64: config['machinePublic'] as String,
          phoneEd25519Seed: seed,
          logger: (level, text, {fields}) =>
              stderr.writeln('handshake[$level]: $text ${fields ?? ''}'),
        ),
        projectStartMessageBuilder: (projectId) =>
            _message('project:start', {'projectId': projectId}),
      );
      live.start();
      await live.ensureEstablished();
      return (active, live, closed);
    }

    var (active, live, closed) = await establish();
    final streamIds = <String, String>{};
    _emit({'check': 'established'});

    for (final raw
        in (config['projects'] as List).cast<Map<String, dynamic>>()) {
      final projectId = raw['id'] as String;
      final name = raw['name'] as String;
      final streamId = await live.bindProject(
        projectId,
        _message('project:start', {'projectId': projectId}),
      );
      streamIds[projectId] = streamId;
      final inbox = _Inbox(live, streamId);
      inboxes.add(inbox);
      await inbox.send(
        _message('file:read', {'projectId': projectId, 'path': 'proof.txt'}),
      );
      final file = await inbox.waitFor(
        (m) => m['type'] == 'file:content' && m['projectId'] == projectId,
      );
      if (file['content'] != '$name:native-host-proof') {
        throw StateError('file:read mismatch on $name');
      }
      _emit({'check': 'project-verified', 'project': name});
      if (name != 'alpha') continue;

      final requestId = _uuid();
      await inbox.send(
        _message('session:create', {
          'requestId': requestId,
          'name': 'native-checkout',
          'isolation': 'worktree',
        }),
      );
      final created = await inbox.waitFor(
        (m) => m['type'] == 'session:result' && m['requestId'] == requestId,
      );
      if (created['ok'] != true) throw StateError('session:create rejected');
      final checkoutId = created['session']['checkoutId'] as String;
      if (created['session']['checkoutKind'] != 'managed-worktree') {
        throw StateError('checkout is not a managed worktree');
      }
      await inbox.send(
        _message('git:list-branches', {
          'projectId': projectId,
          'checkoutId': checkoutId,
        }),
      );
      final branches = await inbox.waitFor(
        (m) => m['type'] == 'git:branches' && m['checkoutId'] == checkoutId,
      );
      if (branches['current'] != created['session']['checkoutBranch']) {
        throw StateError('managed checkout reported the wrong branch');
      }
      _emit({'check': 'managed-checkout-git'});

      const terminalId = 'native-echo';
      await inbox.send(
        _message('terminal:start', {
          'terminalId': terminalId,
          'name': terminalId,
          'command': 'node',
          'args': ['native-echo.cjs'],
        }),
      );
      await inbox.waitFor(
        (m) => m['type'] == 'terminal:started' && m['terminalId'] == terminalId,
      );
      final subscribeId = _uuid();
      await inbox.send(
        _message('terminal:subscribe', {
          'terminalId': terminalId,
          'version': config['terminalProtocolVersion'],
          'requestId': subscribeId,
        }),
      );
      await inbox.waitFor(
        (m) =>
            m['type'] == 'terminal:subscribed' && m['requestId'] == subscribeId,
      );
      await inbox.send(
        _message('terminal:input', {
          'terminalId': terminalId,
          'data': 'native-roundtrip\r',
        }),
      );
      final frame = await inbox.waitFor(
        (m) =>
            m['type'] == 'terminal:frame' &&
            m['terminalId'] == terminalId &&
            (m['ansi'] as String).contains('NATIVE_ECHO:native-roundtrip'),
      );
      if ((frame['sequence'] as int) <= 0) {
        throw StateError('terminal frame carried no sequence');
      }
      await inbox.send(_message('terminal:stop', {'terminalId': terminalId}));
      await inbox.waitFor(
        (m) =>
            m['type'] == 'terminal:display:status' &&
            m['terminalId'] == terminalId &&
            m['code'] == 'ENDED',
      );
      _emit({'check': 'terminal-roundtrip'});
    }
    _emit({
      'check': 'interop-pass',
      'projects': (config['projects'] as List).length,
      'appBinding': 'iroh_quic',
      'transport': 'IrohPeerLink',
    });
    for (
      var cycle = 0;
      cycle < (config['resumeCycles'] as int? ?? 0);
      cycle++
    ) {
      await closed.timeout(const Duration(seconds: 20));
      for (final inbox in inboxes) {
        await inbox.close();
      }
      inboxes.clear();
      await live.dispose();
      await active.close();
      (active, live, closed) = await establish();
      for (final raw
          in (config['projects'] as List).cast<Map<String, dynamic>>()) {
        final id = raw['id'] as String;
        final name = raw['name'] as String;
        final streamId = await live.bindProject(
          id,
          _message('project:start', {'projectId': id}),
        );
        if (streamId != streamIds[id])
          throw StateError('Resume changed host-owned project binding');
        final inbox = _Inbox(live, streamId);
        inboxes.add(inbox);
        await inbox.send(
          _message('file:read', {'projectId': id, 'path': 'proof.txt'}),
        );
        final proof = await inbox.waitFor(
          (m) => m['type'] == 'file:content' && m['projectId'] == id,
        );
        if (proof['content'] != '$name:resume:$cycle')
          throw StateError('Resume returned stale project content');
      }
      _emit({'check': 'resume-verified', 'cycle': cycle});
    }
    // The host flips remote access off once it sees the pass line; a revoked
    // peer must lose the native connection, not merely stop being served.
    await closed.timeout(const Duration(seconds: 20));
    _emit({'check': 'closed-on-revocation'});
  } finally {
    for (final inbox in inboxes) {
      await inbox.close();
    }
    await session?.dispose();
    await link?.close();
    await client.close();
    await keyStore.delete('interop-app');
    RustLib.dispose();
  }
}
