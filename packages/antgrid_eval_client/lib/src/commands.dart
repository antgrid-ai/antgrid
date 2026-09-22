import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:uuid/uuid.dart';

typedef EmitFn = void Function(Map<String, dynamic> response);

/// JSON-line command surface the TS eval harness drives (`DartAppClient`).
///
/// Everything after the relay socket is delegated to the PRODUCTION Dart
/// client: [MachineSession] owns the E2E session, the sealed `{s, m}` stream
/// demux, fragment reassembly and liveness, exactly as the app's
/// `RelayConnection` does. This handler is only a translation layer between
/// stdin JSON actions and that object graph — anything it reimplements is a
/// place where an eval could pass against code the app does not ship.
class _MemoryEndpointKeys implements EndpointKeyStore {
  Uint8List? value;

  @override
  Future<Uint8List?> read(String enrollmentId) async =>
      value == null ? null : Uint8List.fromList(value!);

  @override
  Future<void> write(String enrollmentId, Uint8List secret) async {
    value = Uint8List.fromList(secret);
  }

  @override
  Future<void> delete(String enrollmentId) async {
    value?.fillRange(0, value!.length, 0);
    value = null;
  }
}

class CommandHandler {
  final EmitFn _emit;

  CryptoService? _crypto;
  RelayService? _relay;
  NativeEndpointOwner? _endpoint;
  PeerLink? _payload;
  final _endpointKeys = _MemoryEndpointKeys();
  DeviceIdentity? _identity;
  MachineSession? _session;
  AppSessionHandshaker? _handshaker;

  StreamSubscription<AppState>? _stateSub;
  StreamSubscription<({String projectId, String streamId})>? _streamReadySub;

  /// One subscription per attached [StreamTransport], keyed by streamId
  /// (`"0"` = the machine control plane). Every inbound frame is republished
  /// as an `antgrid-message` event tagged with the stream it arrived on.
  final Map<String, StreamSubscription<InboundMessage>> _streamSubs = {};

  CommandHandler(this._emit);

  Future<void> handle(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String?;
    switch (action) {
      case 'init':
        await _handleInit(cmd);
      case 'connect':
        await _handleConnect(cmd);
      case 'handshake':
        await _handleHandshake(cmd);
      case 'project-start':
        await _handleProjectStart(cmd);
      case 'send-encrypted':
        await _handleSendEncrypted(cmd);
      case 'snapshot':
        await _handleSnapshot(cmd);
      case 'disconnect':
        await _handleDisconnect();
      default:
        _emit({'event': 'error', 'message': 'Unknown action: $action'});
    }
  }

  Future<void> _handleInit(Map<String, dynamic> cmd) async {
    _crypto = CryptoService();
    final (ed25519Private, ed25519Public) = await _crypto!
        .generateEd25519KeyPair();
    final (x25519Private, x25519Public) = await _crypto!
        .generateX25519KeyPair();

    final deviceId = const Uuid().v4();
    final name = cmd['name'] as String? ?? 'eval-client';
    _identity = DeviceIdentity(
      deviceId: deviceId,
      name: name,
      ed25519PrivateKey: ed25519Private,
      ed25519PublicKey: ed25519Public,
      x25519PrivateKey: x25519Private,
      x25519PublicKey: x25519Public,
    );

    _endpoint = await NativeEndpointOwner.create(
      enrollmentId: deviceId,
      keyStore: _endpointKeys,
      approvedRelays: const [],
      initializeNative: () => iroh.Iroh.init(
        libraryPath: Platform.environment['IROH_INTEROP_NATIVE_LIBRARY'],
      ),
    );
    _relay = RelayService(crypto: _crypto!);
    _stateSub = _relay!.stateStream.listen((state) {
      final out = <String, dynamic>{
        'event': 'state',
        'connectionState': state.connectionState.name,
      };
      if (state.peerName != null) out['peerName'] = state.peerName;
      if (state.error != null) out['error'] = state.error;
      _emit(out);
    });

    _emit({
      'event': 'initialized',
      'deviceId': deviceId,
      'publicKey': base64.encode(ed25519Public),
      'x25519PublicKey': base64.encode(x25519Public),
      'endpointId': _endpoint!.endpoint.id.toHex(),
    });
  }

  Future<void> _handleConnect(Map<String, dynamic> cmd) async {
    final relayUrl = cmd['relayUrl'] as String?;
    final licenseToken = cmd['licenseToken'] as String?;
    if (relayUrl == null ||
        licenseToken == null ||
        _relay == null ||
        _endpoint == null ||
        _identity == null) {
      _emit({
        'event': 'error',
        'message':
            'Must init before connect; relayUrl and licenseToken are required',
      });
      return;
    }
    await _relay!.connect(
      relayUrl,
      _identity!,
      licenseToken: licenseToken,
      machineDeviceId: cmd['machineDeviceId'] as String?,
      epoch: cmd['epoch'] as int? ?? 1,
    );
    await _connectPayload(cmd);
    _emit({'event': 'native-connected'});
  }

  Future<void> _connectPayload(Map<String, dynamic> cmd) async {
    final baseUrl = cmd['licenseApiUrl'] as String?;
    final accountId = cmd['accountId'] as String?;
    final enrollmentId = cmd['enrollmentId'] as String?;
    final clientSecret = cmd['clientSecret'] as String?;
    final machineDeviceId = cmd['machineDeviceId'] as String?;
    final addresses = (cmd['nativeAddresses'] as List?)?.cast<String>();
    if (baseUrl == null ||
        accountId == null ||
        enrollmentId == null ||
        clientSecret == null ||
        machineDeviceId == null ||
        addresses == null ||
        addresses.isEmpty) {
      throw ArgumentError('Native enrollment coordinates are required');
    }

    Future<Map<String, dynamic>> request(
      String method,
      String path,
      Map<String, dynamic>? body,
    ) async {
      final client = HttpClient();
      try {
        final tokenRequest = await client.postUrl(
          Uri.parse('$baseUrl/api/auth/oauth2/token'),
        );
        tokenRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('$enrollmentId:$clientSecret'))}',
        );
        final tokenResponse = await tokenRequest.close();
        final tokenText = await utf8.decodeStream(tokenResponse);
        if (tokenResponse.statusCode < 200 || tokenResponse.statusCode >= 300) {
          throw HttpException(
            'Endpoint token failed: ${tokenResponse.statusCode}',
          );
        }
        final token =
            (jsonDecode(tokenText) as Map<String, dynamic>)['access_token']
                as String;
        final peerRequest = await client.openUrl(
          method,
          Uri.parse('$baseUrl$path'),
        );
        peerRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $token',
        );
        if (body != null) {
          peerRequest.headers.contentType = ContentType.json;
          peerRequest.write(jsonEncode(body));
        }
        final response = await peerRequest.close();
        final responseText = await utf8.decodeStream(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'Peer authorization failed: ${response.statusCode} $responseText',
          );
        }
        return (jsonDecode(responseText) as Map).cast<String, dynamic>();
      } finally {
        client.close(force: true);
      }
    }

    final enrollment = EndpointEnrollmentClient(
      request: request,
      accountId: accountId,
      deviceId: _identity!.deviceId,
      enrollmentId: enrollmentId,
    );
    var snapshot = await enrollment.fetchSnapshot();
    final endpointSecret = await _endpointKeys.read(enrollmentId);
    if (endpointSecret == null) throw StateError('Native endpoint key missing');
    if (snapshot.endpoint == null) {
      await enrollment.register(
        deviceSecret: _identity!.ed25519PrivateKey,
        endpointSecret: endpointSecret,
        expectedGeneration: snapshot.registrationGeneration,
      );
    }
    PeerRegistration? target;
    for (var attempt = 0; attempt < 100 && target == null; attempt++) {
      snapshot = await enrollment.fetchSnapshot();
      for (final peer in snapshot.peers) {
        if (peer.deviceId == machineDeviceId) target = peer.endpoint;
      }
      if (target == null)
        await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (target == null)
      throw StateError('Machine did not publish a native endpoint');
    await _payload?.close();
    _payload = await _endpoint!.dial(
      endpointId: target.endpointId,
      localDeviceId: relaySlotId(_identity!.deviceId, machineDeviceId),
      peerDeviceId: machineDeviceId,
      authorized: () => true,
      ipAddresses: addresses,
    );
  }

  /// Establish the E2E session with the machine at [cmd]`['machineDeviceId']`.
  ///
  /// The agent is addressed explicitly: native coordinates come from the
  /// authenticated account inventory, independently of central presence.
  Future<void> _handleHandshake(Map<String, dynamic> cmd) async {
    if (_payload == null || _identity == null || _crypto == null) {
      _emit({'event': 'error', 'message': 'Must init before handshake'});
      return;
    }

    final machineDeviceId = cmd['machineDeviceId'] as String?;
    if (machineDeviceId == null) {
      _emit({
        'event': 'error',
        'message': 'handshake requires machineDeviceId (the agent deviceUuid)',
      });
      return;
    }

    // The agent's pinned Ed25519 pubkey (raw 32 bytes, base64) anchors
    // agent-hello verification. In production the app pins this from the
    // account inventory (a relay-independent anchor); the eval harness threads
    // it in from the agent's bootstrap auth keypair. Abort if absent — we cannot
    // authenticate the agent's X25519 pubkey without it, and deriving on an
    // unverified pubkey re-opens the active-relay DH MITM this signing defeats.
    final agentEd25519PubB64 = cmd['agentEd25519Pub'] as String?;
    if (agentEd25519PubB64 == null) {
      _emit({
        'event': 'error',
        'message': 'handshake requires agentEd25519Pub to verify agent-hello',
      });
      return;
    }

    final attemptTimeoutMs = cmd['attemptTimeoutMs'] as int?;

    await _teardownSession();

    // The eval-client plays the "phone" role: the agent resolves this same
    // Ed25519 identity from the signed-in account's device inventory, so the
    // raw 32-byte seed signs the client-hello transcript. The driver itself is
    // the one the app ships — a second copy here is exactly the drift these
    // scenarios exist to catch.
    final handshaker = _handshaker = AppSessionHandshaker(
      relay: _payload!,
      crypto: _crypto!,
      machineDeviceId: machineDeviceId,
      phoneDeviceId: _identity!.deviceId,
      agentEd25519PubB64: agentEd25519PubB64,
      phoneEd25519Seed: _identity!.ed25519PrivateKey,
      logger: (level, message, {fields}) => _emit({
        'event': 'handshake-diagnostic',
        'level': level.name,
        'message': message,
        if (fields != null) 'fields': fields.map((k, v) => MapEntry(k, '$v')),
      }),
      // The harness owns the retry loop, so it owns the per-attempt budget too:
      // both numbers have to be read together to know the worst case, and
      // splitting them across the two languages is how they drift apart.
      attemptTimeout: attemptTimeoutMs == null
          ? ConnectionHandshake.defaultAttemptTimeout
          : Duration(milliseconds: attemptTimeoutMs),
    );
    final session = _session = MachineSession(
      relay: _payload!,
      machineDeviceId: machineDeviceId,
      handshaker: handshaker,
      projectStartMessageBuilder: (projectId) =>
          _createAbMessage('project:start', {'projectId': projectId}),
    );
    session.start();
    _streamReadySub = session.streamReadyEvents.listen(
      (e) => _emit({
        'event': 'stream-ready',
        'projectId': e.projectId,
        'streamId': e.streamId,
      }),
    );

    try {
      await session.ensureEstablished();
    } catch (e) {
      // `start()` armed the session supervisor, which keeps re-driving a
      // handshake on every peer-online. Leaving it up after reporting failure
      // both churns in the background and leaves `_session` non-null, so a
      // later send-encrypted/snapshot passes its guard and acts on a session
      // that never established.
      await _teardownSession();
      _emit({'event': 'error', 'message': 'Handshake failed: $e'});
      return;
    }

    // Attach the control plane so machine-scoped frames (agent:projects,
    // stream-ready, host verbs) are observable; project frames get their own
    // transport per `project-start`.
    _attachStream(kControlStreamId);
    _emit({'event': 'handshake-complete'});
  }

  /// Drill into a project: `project:start` on the control plane, then await the
  /// agent's `stream-ready`. Resolves at 0 RTT when the advert
  /// already carried the stream.
  Future<void> _handleProjectStart(Map<String, dynamic> cmd) async {
    final session = _session;
    final projectId = cmd['projectId'] as String?;
    if (session == null || projectId == null) {
      _emit({
        'event': 'error',
        'message':
            'Must complete handshake before project-start, and '
            'projectId is required',
      });
      return;
    }
    try {
      final streamId = await session.bindProject(
        projectId,
        _createAbMessage('project:start', {'projectId': projectId}),
      );
      _attachStream(streamId);
      _emit({
        'event': 'project-started',
        'projectId': projectId,
        'streamId': streamId,
      });
    } catch (e) {
      _emit({'event': 'error', 'message': 'project-start failed: $e'});
    }
  }

  /// Send an AbMessage sealed inside a `{s, m}` envelope. `streamId` omitted =
  /// the machine control plane (`s` absent).
  Future<void> _handleSendEncrypted(Map<String, dynamic> cmd) async {
    final session = _session;
    final data = cmd['data'] as Map<String, dynamic>?;
    if (session == null || data == null) {
      _emit({
        'event': 'error',
        'message':
            'Must complete handshake before send-encrypted, and data '
            'is required',
      });
      return;
    }
    await session.sendOnStream(
      cmd['streamId'] as String? ?? kControlStreamId,
      data,
      'control',
    );
  }

  /// Pull-then-replay durable state — mirrors what a `ProjectSession` does on
  /// bind. The agent's live welcome burst may be suppressed by the bridge's
  /// replay-cache dedup, so the app never relies on it: it PULLS the cached
  /// snapshot via `state.snapshot` and replays the frames into its own message
  /// stream. [StreamTransport.refreshSnapshot] does exactly that, and the
  /// frames surface through the [_attachStream] subscription as
  /// `antgrid-message` events, so type waiters resolve instead of racing the
  /// deduped burst.
  ///
  /// The production pull EXCLUDES `tree:full` — the app's file tree arrives
  /// through `FileService`'s per-checkout `file:tree:snapshot:request`
  /// hydrator instead, and pulling it here as well doubled the heaviest frame
  /// on every connect. This client has no such hydrator, and the bus replays
  /// nothing on subscribe, so a project stream asks for the heavy types in a
  /// round trip of its own to keep the evals' `tree:full` waiters answerable.
  Future<void> _handleSnapshot(Map<String, dynamic> cmd) async {
    final session = _session;
    if (session == null) {
      _emit({
        'event': 'error',
        'message': 'Must complete handshake before snapshot',
      });
      return;
    }
    final streamId = cmd['streamId'] as String? ?? kControlStreamId;
    _attachStream(streamId);
    final transport = session.streamFor(streamId);
    await transport.refreshSnapshot();
    // The control plane's bus never caches a tree; asking would spend a round
    // trip on an empty answer.
    if (streamId != kControlStreamId) {
      await _pullHeavyFrames(transport, streamId);
    }
    _emit({'event': 'snapshot-complete', 'streamId': streamId});
  }

  /// Frames the production snapshot pull leaves to the app's hydrators. Kept
  /// in lockstep with `_kHeavyReplayTypes` in `machine_session.dart`.
  static const _kHeavyReplayTypes = <String>['tree:full'];

  /// Emitted directly rather than pushed back through the transport: the
  /// [_attachStream] subscription only sees what the transport itself fans
  /// out, and a raw `request` bypasses that path.
  Future<void> _pullHeavyFrames(
    StreamTransport transport,
    String streamId,
  ) async {
    try {
      final snap = await transport.request(
        'state.snapshot',
        params: {'types': _kHeavyReplayTypes},
      );
      for (final raw in (snap['frames'] as List?) ?? const []) {
        if (raw is! Map) continue;
        _emit({
          'event': 'antgrid-message',
          'streamId': streamId,
          'channel': 'control',
          'data': raw.cast<String, dynamic>(),
        });
      }
    } catch (_) {
      // A missing tree is the waiter's problem to report, with its own
      // message; failing the whole snapshot here would hide the state half
      // that did land.
    }
  }

  Future<void> _handleDisconnect() async {
    await _teardownSession();
    await _stateSub?.cancel();
    _stateSub = null;
    _relay?.dispose();
    _relay = null;
    await _payload?.close();
    _payload = null;
    await _endpoint?.close();
    _endpoint = null;
    await _endpointKeys.delete(_identity?.deviceId ?? '');
    _crypto = null;
    _identity = null;
    _emit({'event': 'disconnected'});
  }

  /// Republish every frame the session demuxes to [streamId]. Idempotent: the
  /// transport is created on first use and reused after (a second subscription
  /// would double-emit, since `messages` also replays the snapshot cache).
  void _attachStream(String streamId) {
    if (_streamSubs.containsKey(streamId)) return;
    final transport = _session!.streamFor(streamId);
    _streamSubs[streamId] = transport.messages.listen((msg) {
      _emit({
        'event': 'antgrid-message',
        'streamId': streamId,
        'channel': msg.channel,
        'data': msg.json,
      });
    });
  }

  Future<void> _teardownSession() async {
    _handshaker?.abort();
    _handshaker = null;
    await _streamReadySub?.cancel();
    _streamReadySub = null;
    for (final sub in _streamSubs.values) {
      await sub.cancel();
    }
    _streamSubs.clear();
    await _session?.dispose();
    _session = null;
  }

  /// Mirror of the app's `createAbMessage` (`app/lib/models/ab_message.dart`) —
  /// the bridge rejects a verb without `id`/`timestamp`.
  Map<String, dynamic> _createAbMessage(
    String type,
    Map<String, dynamic> fields,
  ) => {
    'type': type,
    'id': const Uuid().v4(),
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    ...fields,
  };
}
