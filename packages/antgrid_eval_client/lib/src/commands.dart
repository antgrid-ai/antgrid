import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

typedef EmitFn = void Function(Map<String, dynamic> response);

class CommandHandler {
  final EmitFn _emit;

  CryptoService? _crypto;
  RelayService? _relay;
  DeviceIdentity? _identity;
  SessionKeys? _sessionKeys;

  StreamSubscription<AppState>? _stateSub;
  StreamSubscription<IncomingRouteMessage>? _messageSub;

  /// During handshake, control-channel messages are routed here instead of
  /// the default message listener.
  Completer<IncomingRouteMessage>? _handshakeCompleter;

  /// True while a handshake is running. Control messages that arrive between
  /// the two `_waitForControlMessage` calls (no completer armed yet) are
  /// buffered here rather than falling through to `_emitRawMessage`, which
  /// would `utf8.decode` the encrypted `agent-ready` payload and throw.
  bool _handshaking = false;
  final List<IncomingRouteMessage> _pendingControl = [];

  CommandHandler(this._emit);

  Future<void> handle(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String?;
    switch (action) {
      case 'init':
        await _handleInit(cmd);
      case 'connect':
        await _handleConnect(cmd);
      case 'pair':
        await _handlePair(cmd);
      case 'handshake':
        await _handleHandshake(cmd);
      case 'send':
        _handleSend(cmd);
      case 'send-encrypted':
        await _handleSendEncrypted(cmd);
      case 'snapshot':
        await _handleSnapshot(cmd);
      case 'disconnect':
        _handleDisconnect();
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

    // Listen to state changes
    _stateSub = _relay!.stateStream.listen((state) {
      // Pull-model: the app/eval-client sends `handshake:client-hello` first and
      // the agent replies (`handshake:agent-hello`, then the encrypted
      // `agent-ready`). Start buffering control frames at `paired` so handshake
      // frames arriving between the two `_waitForControlMessage` awaits aren't
      // dropped into `_emitRawMessage` (which would utf8-decode the encrypted
      // agent-ready and throw).
      if (state.connectionState.name == 'paired') _handshaking = true;
      final out = <String, dynamic>{
        'event': 'state',
        'connectionState': state.connectionState.name,
      };
      if (state.peerDeviceId != null) out['peerDeviceId'] = state.peerDeviceId;
      if (state.peerName != null) out['peerName'] = state.peerName;
      if (state.error != null) out['error'] = state.error;
      _emit(out);
    });

    // Listen to incoming messages
    _messageSub = _relay!.messageStream.listen((msg) {
      // If handshake is in progress, route control messages to the completer
      if (msg.channel == 'control' && _handshakeCompleter != null) {
        final c = _handshakeCompleter!;
        _handshakeCompleter = null;
        c.complete(msg);
        return;
      }

      // Handshake running but no completer armed yet (the window between the
      // two `_waitForControlMessage` awaits). Buffer instead of dropping —
      // these are handshake frames (e.g. encrypted agent-ready), not app data.
      if (msg.channel == 'control' && _handshaking) {
        _pendingControl.add(msg);
        return;
      }

      // Try to decrypt if we have session keys and it's a control message
      if (msg.channel == 'control' && _sessionKeys != null) {
        unawaited(_tryDecryptAndEmit(msg));
        return;
      }

      // Emit raw message
      _emitRawMessage(msg);
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
    // licenseToken is optional. App/phone clients never present one (they
    // inherit auth via a paired agent's signed pair-approval). Only agent-
    // shaped legacy callers pass it through.
    final licenseToken = cmd['licenseToken'] as String?;
    if (relayUrl == null || _relay == null || _identity == null) {
      _emit({
        'event': 'error',
        'message': 'Must init before connect, and relayUrl is required',
      });
      return;
    }
    await _relay!.connect(relayUrl, _identity!, licenseToken: licenseToken);
  }

  Future<void> _handlePair(Map<String, dynamic> cmd) async {
    final targetDeviceId = cmd['targetDeviceId'] as String?;
    if (targetDeviceId == null || _relay == null || _identity == null) {
      _emit({
        'event': 'error',
        'message': 'Must init before pair, and targetDeviceId is required',
      });
      return;
    }
    // Eval-client identity uses Ed25519 for both relay auth and pair-approval
    // signing, so the same key pair plays the "phone pubkey" role here.
    final phonePubkey = cmd['phonePubkey'] as String? ??
        base64.encode(_identity!.ed25519PublicKey);
    final phoneDeviceId =
        cmd['phoneDeviceId'] as String? ?? _identity!.deviceId;
    final nonce = cmd['nonce'] as String? ?? const Uuid().v4();
    final requestedAt = DateTime.now().toUtc().toIso8601String();
    // `_identity!.ed25519PrivateKey` is the raw 32-byte Ed25519 seed (the
    // `cryptography` package stores Ed25519 keys as seeds via
    // `extractPrivateKeyBytes`), matching what `signPairRequest` expects.
    final phoneSignature = await signPairRequest(
      agentDeviceId: targetDeviceId,
      phonePubkey: phonePubkey,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      requestedAt: requestedAt,
      privSeed: _identity!.ed25519PrivateKey,
    );
    _relay!.requestPair(
      agentDeviceId: targetDeviceId,
      phonePubkey: phonePubkey,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      requestedAt: requestedAt,
      phoneSignature: phoneSignature,
      pairCode: cmd['pairCode'] as String?,
      label: cmd['label'] as String?,
    );
  }

  Future<void> _handleHandshake(Map<String, dynamic> cmd) async {
    if (_relay == null || _identity == null || _crypto == null) {
      _emit({'event': 'error', 'message': 'Must init before handshake'});
      return;
    }

    final peerId = _relay!.currentState.peerDeviceId;
    if (peerId == null) {
      _emit({'event': 'error', 'message': 'Not paired — no peer device ID'});
      return;
    }

    // The agent's pinned Ed25519 pubkey (raw 32 bytes, base64) anchors
    // agent-hello verification. In production the app pins this from the
    // recent-agents store (a relay-independent anchor); the eval harness threads
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

    // Sign/verify materials. The eval-client plays the "phone" role: its
    // Ed25519 identity is the SAME key the agent pinned at pairing as
    // `phonePubkey` (see _handlePair), so `_identity!.ed25519PrivateKey` (the
    // raw 32-byte seed) signs the client-hello transcript. `phoneDeviceId` is
    // the eval-client's relay deviceId; `agentDeviceId` is the agent's relay
    // registration id (== the paired peer id).
    final phoneSeed = _identity!.ed25519PrivateKey;
    final phoneDeviceId = _identity!.deviceId;
    final agentDeviceId = peerId;
    // SECURITY: fresh phone X25519 keypair per handshake attempt (full forward
    // secrecy — both ephemerals fresh). Do NOT reuse identity.x25519PublicKey.
    final (phoneX25519Priv, phoneX25519Pub) =
        await _crypto!.generateX25519KeyPair();
    final phoneX25519PubB64 = base64.encode(phoneX25519Pub);
    // Fresh per-attempt 16-byte secure-random nonce, sent on the client-hello
    // and bound into both transcript signatures.
    final rng = Random.secure();
    final nonceB64 =
        base64.encode(List<int>.generate(16, (_) => rng.nextInt(256)));
    final nonce = base64.decode(nonceB64);

    _handshaking = true;
    try {
      // 1. Send client-hello, signed over the v2 handshake transcript. The phone
      // signs BEFORE it knows the agent X25519 pub, so the agent-pub slot is
      // EMPTY (zero-length). The agent verifies with the same empty slot. The
      // agent's OWN signature (verified on agent-hello) binds the real agent
      // X25519 pubkey and defeats DH MITM.
      final phoneTranscript = buildTranscriptV2(TranscriptFields(
        registrationId: agentDeviceId,
        role: 'phone',
        agentDeviceId: agentDeviceId,
        phoneDeviceId: phoneDeviceId,
        agentX25519Pub: Uint8List(0),
        phoneX25519Pub: phoneX25519Pub,
        nonce: nonce,
      ));
      final clientHelloSig = await signTranscriptV2(
        transcript: phoneTranscript,
        ed25519Seed: phoneSeed,
      );
      final clientHello = jsonEncode({
        'type': 'handshake:client-hello',
        'pubkey': phoneX25519PubB64,
        'nonce': nonceB64,
        'sig': clientHelloSig,
      });
      _relay!.sendMessage(peerId, 'control', Uint8List.fromList(utf8.encode(clientHello)));

      // 2. Wait for agent-hello (plaintext JSON with agent's X25519 pubkey + sig)
      final agentHelloMsg = await _waitForControlMessage();
      final agentHelloPayload = utf8.decode(agentHelloMsg.payload);

      Map<String, dynamic> agentHelloJson;
      try {
        agentHelloJson = jsonDecode(agentHelloPayload) as Map<String, dynamic>;
      } catch (_) {
        _emit({
          'event': 'error',
          'message': 'Expected agent-hello JSON, got: $agentHelloPayload',
        });
        return;
      }

      if (agentHelloJson['type'] != 'handshake:agent-hello') {
        _emit({
          'event': 'error',
          'message':
              'Expected handshake:agent-hello, got: ${agentHelloJson['type']}',
        });
        return;
      }

      final agentPubB64 = agentHelloJson['pubkey'] as String;
      final agentSig = agentHelloJson['sig'] as String?;
      // SECURITY: abort if the agent-hello carries no transcript signature.
      // Deriving on an unsigned pubkey would re-open the active-relay DH MITM.
      if (agentSig == null) {
        _emit({
          'event': 'error',
          'message': 'agent-hello missing sig, rejecting handshake',
        });
        return;
      }
      final agentX25519Pub = base64.decode(agentPubB64);
      if (agentX25519Pub.length != 32) {
        _emit({'event': 'error', 'message': 'agent-hello pubkey wrong length'});
        return;
      }
      // SECURITY: verify the agent's v2 transcript signature against the pinned
      // agent Ed25519 identity BEFORE deriving. A tampered agent-hello pubkey
      // (active relay swapping the DH key) fails this check.
      final agentTranscript = buildTranscriptV2(TranscriptFields(
        registrationId: agentDeviceId,
        role: 'agent',
        agentDeviceId: agentDeviceId,
        phoneDeviceId: phoneDeviceId,
        agentX25519Pub: agentX25519Pub,
        phoneX25519Pub: phoneX25519Pub,
        nonce: nonce,
      ));
      final agentVerified = await verifyTranscriptSigV2(
        transcript: agentTranscript,
        ed25519PubB64: agentEd25519PubB64,
        sigB64: agentSig,
      );
      if (!agentVerified) {
        _emit({
          'event': 'error',
          'message':
              'agent-hello transcript signature invalid, rejecting (possible MITM)',
        });
        return;
      }

      // 3. Derive directional session keys (v2 key schedule)
      final ss = await x25519SharedSecret(
        privateKey: phoneX25519Priv,
        peerPublicKey: agentX25519Pub,
      );
      final keys = await deriveSessionKeysV2(ss, agentTranscript);

      // 4. Wait for encrypted agent-ready; decrypt with a2p key
      final agentReadyMsg = await _waitForControlMessage();
      final t = E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p);
      final decrypted = await t.open(agentReadyMsg.payload);
      if (decrypted == null) {
        _emit({
          'event': 'error',
          'message': 'Failed to decrypt agent-ready',
        });
        keys.zeroize();
        return;
      }

      final agentReadyJson = jsonDecode(decrypted) as Map<String, dynamic>;
      if (agentReadyJson['type'] != 'handshake:agent-ready') {
        _emit({
          'event': 'error',
          'message':
              'Expected handshake:agent-ready, got: ${agentReadyJson['type']}',
        });
        keys.zeroize();
        return;
      }

      // 5. Verify agent confirm tag
      final confirmB64 = agentReadyJson['confirm'] as String?;
      if (confirmB64 == null) {
        _emit({'event': 'error', 'message': 'agent-ready missing confirm tag'});
        keys.zeroize();
        return;
      }
      final expectedAgentTag = await agentConfirmTagV2(keys.confirm);
      Uint8List presentedTag;
      try {
        presentedTag = base64.decode(confirmB64);
      } catch (_) {
        _emit({'event': 'error', 'message': 'agent-ready confirm tag decode error'});
        keys.zeroize();
        return;
      }
      if (!verifyConfirmTagV2(expectedAgentTag, presentedTag)) {
        _emit({'event': 'error', 'message': 'agent-ready confirm tag invalid'});
        keys.zeroize();
        return;
      }

      // Keys are good — install them
      _sessionKeys = keys;

      // 6. Send sealed app:ready carrying the phone confirm tag
      final phoneTag = await phoneConfirmTagV2(keys.confirm);
      final appReadyPlain = jsonEncode({
        'type': 'app:ready',
        'confirm': base64.encode(phoneTag),
      });
      final appReadyEncrypted = await t.seal(appReadyPlain);
      _relay!.sendMessage(peerId, 'control', appReadyEncrypted);

      _emit({'event': 'handshake-complete'});
    } catch (e) {
      _sessionKeys = null;
      _emit({'event': 'error', 'message': 'Handshake failed: $e'});
    } finally {
      _handshaking = false;
      // Re-dispatch any control messages buffered during the handshake (e.g. an
      // early post-handshake frame) through the normal decrypt path so none are
      // lost. Empty in the common case (welcome burst follows app:ready).
      final leftover = List<IncomingRouteMessage>.from(_pendingControl);
      _pendingControl.clear();
      for (final m in leftover) {
        if (_sessionKeys != null) {
          unawaited(_tryDecryptAndEmit(m));
        }
      }
    }
  }

  void _handleSend(Map<String, dynamic> cmd) {
    final to = cmd['to'] as String?;
    final channel = cmd['channel'] as String?;
    final payload = cmd['payload'] as String?;
    if (to == null || channel == null || payload == null || _relay == null) {
      _emit({
        'event': 'error',
        'message': 'Must init, and to/channel/payload are required',
      });
      return;
    }
    _relay!.sendMessage(to, channel, Uint8List.fromList(utf8.encode(payload)));
  }

  Future<void> _handleSendEncrypted(Map<String, dynamic> cmd) async {
    final data = cmd['data'] as Map<String, dynamic>?;
    if (data == null || _relay == null) {
      _emit({
        'event': 'error',
        'message': 'Must init, and data is required',
      });
      return;
    }
    if (_sessionKeys == null) {
      _emit({
        'event': 'error',
        'message': 'No session keys — must complete handshake first',
      });
      return;
    }

    final peerId = _relay!.currentState.peerDeviceId;
    if (peerId == null) {
      _emit({'event': 'error', 'message': 'Not paired — no peer device ID'});
      return;
    }

    final t = E2eTransportDart(
      sendKey: _sessionKeys!.p2a,
      recvKey: _sessionKeys!.a2p,
    );
    final encrypted = await t.seal(jsonEncode(data));
    _relay!.sendMessage(peerId, 'control', encrypted);
  }

  /// Pull-then-replay welcome state — mirrors the production app's
  /// `RelayTransport.connect()`. After the handshake the agent's live welcome
  /// burst (agent:status/tree:full/git:status) may be suppressed by the
  /// MessageBus replay-cache dedup when an earlier identical burst already
  /// populated it. The real app never relies on that burst — it PULLS the cached
  /// snapshot via the `state.snapshot` RPC and replays the frames into its own
  /// stream. The response is fanned out into per-frame `antgrid-message` events
  /// in [_tryDecryptAndEmit], so waiters for agent:status/tree:full resolve
  /// instead of racing the deduped burst.
  Future<void> _handleSnapshot(Map<String, dynamic> cmd) async {
    if (_sessionKeys == null || _relay == null) {
      _emit({
        'event': 'error',
        'message': 'Must complete handshake before snapshot',
      });
      return;
    }
    final peerId = _relay!.currentState.peerDeviceId;
    if (peerId == null) {
      _emit({'event': 'error', 'message': 'Not paired — no peer device ID'});
      return;
    }
    final requestId = 'snap-${DateTime.now().microsecondsSinceEpoch}';
    final req = {
      'type': 'request',
      'id': requestId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'requestId': requestId,
      'method': 'state.snapshot',
      'params': {
        'types': ['*'],
      },
    };
    final t = E2eTransportDart(
      sendKey: _sessionKeys!.p2a,
      recvKey: _sessionKeys!.a2p,
    );
    final encrypted = await t.seal(jsonEncode(req));
    _relay!.sendMessage(peerId, 'control', encrypted);
  }

  void _handleDisconnect() {
    _stateSub?.cancel();
    _stateSub = null;
    _messageSub?.cancel();
    _messageSub = null;
    _relay?.dispose();
    _relay = null;
    _crypto = null;
    _identity = null;
    _sessionKeys?.zeroize();
    _sessionKeys = null;
    _handshaking = false;
    _pendingControl.clear();
    _emit({'event': 'disconnected'});
  }

  /// Wait for the next control-channel message using a completer that
  /// intercepts messages from the main message listener.
  Future<IncomingRouteMessage> _waitForControlMessage() {
    // Drain any control message buffered between awaits before arming a waiter.
    if (_pendingControl.isNotEmpty) {
      return Future.value(_pendingControl.removeAt(0));
    }
    final completer = Completer<IncomingRouteMessage>();
    _handshakeCompleter = completer;

    // Timeout after 30 seconds
    final timer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        _handshakeCompleter = null;
        completer.completeError(
          TimeoutException('Timed out waiting for control message'),
        );
      }
    });

    return completer.future.whenComplete(() => timer.cancel());
  }

  void _emitRawMessage(IncomingRouteMessage msg) {
    final payloadStr = utf8.decode(msg.payload);
    final out = <String, dynamic>{
      'event': 'message',
      'from': msg.from,
      'channel': msg.channel,
      'payload': payloadStr,
    };

    // Try to parse payload as JSON for convenience
    try {
      out['parsed'] = jsonDecode(payloadStr);
    } catch (_) {
      // Not JSON — leave parsed absent
    }

    _emit(out);
  }

  Future<void> _tryDecryptAndEmit(IncomingRouteMessage msg) async {
    final keys = _sessionKeys;
    if (keys == null) {
      _emitRawMessage(msg);
      return;
    }
    final t = E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p);
    final decrypted = await t.open(msg.payload);
    if (decrypted != null) {
      try {
        final data = jsonDecode(decrypted) as Map<String, dynamic>;
        // Welcome-replay: a `state.snapshot` response carries the cached frames
        // (agent:status/tree:full/git:status). Fan each out as its own
        // antgrid-message so waiters resolve — mirroring the app replaying
        // `_snapshotCache` into its message stream (relay_transport.dart).
        final result = data['result'];
        if (data['type'] == 'response' && result is Map && result['frames'] is List) {
          for (final frame in result['frames'] as List) {
            if (frame is Map) {
              _emit({
                'event': 'antgrid-message',
                'from': msg.from,
                'data': frame.cast<String, dynamic>(),
              });
            }
          }
          _emit({'event': 'snapshot-complete'});
          return;
        }
        _emit({
          'event': 'antgrid-message',
          'from': msg.from,
          'data': data,
        });
        return;
      } catch (_) {
        // Decrypted but not JSON — emit as raw
      }
    }

    // Couldn't decrypt or parse — emit as raw message
    _emitRawMessage(msg);
  }
}
