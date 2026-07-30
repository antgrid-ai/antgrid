import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
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
class CommandHandler {
  final EmitFn _emit;

  CryptoService? _crypto;
  RelayService? _relay;
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
    final (ed25519Private, ed25519Public) =
        await _crypto!.generateEd25519KeyPair();
    final (x25519Private, x25519Public) =
        await _crypto!.generateX25519KeyPair();

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
    });
  }

  Future<void> _handleConnect(Map<String, dynamic> cmd) async {
    final relayUrl = cmd['relayUrl'] as String?;
    // v3 admission: every app hello carries its own account license token
    // (design §4.2). There is no token-free app dial to fall back to, so a
    // missing token is a caller bug, not a mode.
    final licenseToken = cmd['licenseToken'] as String?;
    if (relayUrl == null ||
        licenseToken == null ||
        _relay == null ||
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
      // One dial per (freshly keyed) process, so there is never a prior
      // connection instance of this deviceId for the relay to arbitrate
      // against — the counter has nothing to advance past.
      epoch: cmd['epoch'] as int? ?? 1,
    );
  }

  /// Establish the E2E session with the machine at [cmd]`['machineDeviceId']`.
  ///
  /// The agent is addressed explicitly: with pairing gone there is no
  /// relay-supplied peer id to infer it from, and the app has the same problem
  /// — it dials coordinates it already holds (`RecentAgent` / the account
  /// inventory) rather than learning them from the relay.
  Future<void> _handleHandshake(Map<String, dynamic> cmd) async {
    if (_relay == null || _identity == null || _crypto == null) {
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
      relay: _relay!,
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
      relay: _relay!,
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
  /// agent's `stream-ready` (design §7.4). Resolves at 0 RTT when the advert
  /// already carried the stream.
  Future<void> _handleProjectStart(Map<String, dynamic> cmd) async {
    final session = _session;
    final projectId = cmd['projectId'] as String?;
    if (session == null || projectId == null) {
      _emit({
        'event': 'error',
        'message': 'Must complete handshake before project-start, and '
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
        'message': 'Must complete handshake before send-encrypted, and data '
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
    await session.streamFor(streamId).refreshSnapshot();
    _emit({'event': 'snapshot-complete', 'streamId': streamId});
  }

  Future<void> _handleDisconnect() async {
    await _teardownSession();
    await _stateSub?.cancel();
    _stateSub = null;
    _relay?.dispose();
    _relay = null;
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
