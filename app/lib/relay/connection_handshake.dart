import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/foundation.dart';

import '../util/secure_nonce.dart';

/// Runs ONE app-initiated v2-crypto handshake to `established` over a single
/// [RelayService] socket. v3 changes the conversation around the (unchanged)
/// crypto: a phone-generated `attemptId` correlates every frame, frames go out
/// kind-1 (handshake plaintext) / kind-0 (sealed), and the phone retransmits
/// `app:ready` until the agent's sealed `established` arrives — only then does
/// [run] complete (design §6.1). All per-run state is instance-local.
class ConnectionHandshake {
  ConnectionHandshake({
    required RelayService relay,
    required CryptoService crypto,
    required String machineDeviceId,
    required String phoneDeviceId,
    required String agentEd25519PubB64,
    required List<int> phoneEd25519Seed,
    Duration attemptTimeout = const Duration(seconds: 10),
    Duration appReadyRetransmit = const Duration(seconds: 2),
  }) : _relay = relay,
       _crypto = crypto,
       _machineDeviceId = machineDeviceId,
       _phoneDeviceId = phoneDeviceId,
       _agentEd25519PubB64 = agentEd25519PubB64,
       _phoneEd25519Seed = phoneEd25519Seed,
       _attemptTimeout = attemptTimeout,
       _appReadyRetransmit = appReadyRetransmit;

  final RelayService _relay;
  final CryptoService _crypto;

  /// The bare machine deviceUuid — the transcript's `registrationId`/
  /// `agentDeviceId` and the routing `to` for handshake frames.
  final String _machineDeviceId;
  final String _phoneDeviceId;
  final String _agentEd25519PubB64;
  final List<int> _phoneEd25519Seed;
  final Duration _attemptTimeout;
  final Duration _appReadyRetransmit;

  bool _cancelled = false;
  StreamSubscription<IncomingRouteMessage>? _messageSub;
  Timer? _appReadyTimer;

  void cancel() {
    _cancelled = true;
    _messageSub?.cancel();
    _messageSub = null;
    _appReadyTimer?.cancel();
    _appReadyTimer = null;
  }

  /// Runs one handshake attempt (fresh `attemptId`). Returns the confirmed
  /// [SessionKeys] once the sealed `established` arrives, or null on timeout /
  /// verification failure / cancellation.
  Future<SessionKeys?> run() async {
    if (_cancelled) return null;

    final attemptId = secureNonceB64();
    final nonceB64 = secureNonceB64();
    final nonce = base64.decode(nonceB64);
    final (phoneX25519Priv, phoneX25519Pub) =
        await _crypto.generateX25519KeyPair();
    var phoneX25519PrivScrubbed = false;
    final phoneX25519PubB64 = base64.encode(phoneX25519Pub);
    final established = Completer<SessionKeys>();
    SessionKeys? derivedKeys;
    Future<SessionKeys?>? keysFuture;
    var appReadySent = false;

    final sub = _relay.messageStream.listen((msg) async {
      if (msg.channel != 'control') return;

      if (msg.kind == FrameKind.handshake) {
        // Kind-1 plaintext: the only expected type here is agent-hello.
        Map<String, dynamic>? j;
        try {
          j = jsonDecode(utf8.decode(msg.payload)) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        if (j['type'] != 'handshake:agent-hello') return;
        if (j['attemptId'] != attemptId) return;
        final pubkey = j['pubkey'] as String?;
        final sig = j['sig'] as String?;
        if (pubkey == null || sig == null) return;

        Uint8List agentPubkey;
        try {
          agentPubkey = base64.decode(pubkey);
        } catch (_) {
          return;
        }
        if (agentPubkey.length != 32) return;

        keysFuture ??= () async {
          final agentTranscript = buildTranscriptV2(
            TranscriptFields(
              registrationId: _machineDeviceId,
              role: 'agent',
              agentDeviceId: _machineDeviceId,
              phoneDeviceId: _phoneDeviceId,
              agentX25519Pub: agentPubkey,
              phoneX25519Pub: phoneX25519Pub,
              nonce: nonce,
            ),
          );
          final ok = await verifyTranscriptSigV2(
            transcript: agentTranscript,
            ed25519PubB64: _agentEd25519PubB64,
            sigB64: sig,
          );
          if (!ok) {
            debugPrint(
              'ConnectionHandshake.run: agent-hello v2 sig invalid '
              '(possible MITM)',
            );
            keysFuture = null;
            return null;
          }
          final ss = await x25519SharedSecret(
            privateKey: phoneX25519Priv,
            peerPublicKey: agentPubkey,
          );
          phoneX25519Priv.fillRange(0, phoneX25519Priv.length, 0);
          phoneX25519PrivScrubbed = true;
          final dk = await deriveSessionKeysV2(ss, agentTranscript);
          derivedKeys = dk;
          return dk;
        }();
        return;
      }

      // Kind-0 sealed: agent-ready or established, sealed under the derived
      // (candidate) keys. Decrypt-or-drop.
      final kf = keysFuture;
      if (kf == null) return;
      final keys = await kf;
      if (keys == null) return;

      final t = E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p);
      final dec = await t.open(msg.payload);
      if (dec == null) return;

      Map<String, dynamic> json;
      try {
        json = jsonDecode(dec) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      if (json['attemptId'] != attemptId) return;
      final type = json['type'];

      if (type == 'handshake:agent-ready') {
        final confirmB64 = json['confirm'] as String?;
        if (confirmB64 == null) return;
        final expectedAgentTag = await agentConfirmTagV2(keys.confirm);
        Uint8List presented;
        try {
          presented = base64.decode(confirmB64);
        } catch (_) {
          return;
        }
        if (!verifyConfirmTagV2(expectedAgentTag, presented)) {
          debugPrint(
            'ConnectionHandshake.run: agent-ready confirm tag invalid, '
            'rejecting',
          );
          return;
        }
        if (!appReadySent) {
          appReadySent = true;
          _startAppReadyRetransmit(keys, attemptId);
        }
      } else if (type == 'established') {
        if (!established.isCompleted) established.complete(keys);
      }
    });
    _messageSub = sub;

    try {
      final phoneTranscript = buildTranscriptV2(
        TranscriptFields(
          registrationId: _machineDeviceId,
          role: 'phone',
          agentDeviceId: _machineDeviceId,
          phoneDeviceId: _phoneDeviceId,
          agentX25519Pub: Uint8List(0),
          phoneX25519Pub: phoneX25519Pub,
          nonce: nonce,
        ),
      );
      final clientHelloSig = await signTranscriptV2(
        transcript: phoneTranscript,
        ed25519Seed: _phoneEd25519Seed,
      );
      final clientHello = <String, dynamic>{
        'type': 'handshake:client-hello',
        'attemptId': attemptId,
        'pubkey': phoneX25519PubB64,
        'nonce': nonceB64,
        'sig': clientHelloSig,
      };
      _relay.sendMessage(
        _machineDeviceId,
        'control',
        Uint8List.fromList(utf8.encode(jsonEncode(clientHello))),
        kind: FrameKind.handshake,
      );

      final keys = await established.future.timeout(_attemptTimeout);
      if (_cancelled) return null;
      return keys;
    } on TimeoutException {
      return null;
    } catch (e, st) {
      debugPrint('ConnectionHandshake.run error: $e\n$st');
      return null;
    } finally {
      _appReadyTimer?.cancel();
      _appReadyTimer = null;
      if (identical(_messageSub, sub)) _messageSub = null;
      await sub.cancel();
      // Scrub the ephemeral X25519 private key ONLY when no DH ran on it (see
      // the DH future above, which scrubs immediately after the shared secret).
      if (keysFuture == null && !phoneX25519PrivScrubbed) {
        phoneX25519Priv.fillRange(0, phoneX25519Priv.length, 0);
      }
      // Zeroize the derived keys unless the caller (MachineSession) took them:
      // on a completed established they are returned and owned by the caller.
      if (!established.isCompleted) derivedKeys?.zeroize();
    }
  }

  /// Retransmit sealed `app:ready` every [_appReadyRetransmit] (re-sealed each
  /// time; GCM nonces are per-seal) until `established` arrives or the attempt
  /// times out — closes the dropped-`app:ready` wedge (design §6.1 step 5).
  void _startAppReadyRetransmit(SessionKeys keys, String attemptId) {
    Future<void> send() async {
      if (_cancelled) return;
      try {
        final phoneTag = await phoneConfirmTagV2(keys.confirm);
        final t = E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p);
        // Bare session frame (matches the bridge's handleAppReady) — session
        // frames are not `createAbMessage`-wrapped envelopes.
        final sealed = await t.seal(
          jsonEncode({
            'type': 'app:ready',
            'attemptId': attemptId,
            'confirm': base64.encode(phoneTag),
          }),
        );
        if (_cancelled) return;
        _relay.sendMessage(_machineDeviceId, 'control', sealed);
      } catch (e) {
        debugPrint('ConnectionHandshake: app:ready seal/send failed: $e');
      }
    }

    unawaited(send());
    _appReadyTimer =
        Timer.periodic(_appReadyRetransmit, (_) => unawaited(send()));
  }
}

/// [SessionHandshaker] the pure-Dart [MachineSession] drives. Each [perform]
/// runs a FRESH [ConnectionHandshake] (new `attemptId`) on the live socket, so
/// a rekey never collides with a superseded attempt.
class AppSessionHandshaker implements SessionHandshaker {
  AppSessionHandshaker({
    required RelayService relay,
    required CryptoService crypto,
    required String machineDeviceId,
    required String phoneDeviceId,
    required String agentEd25519PubB64,
    required List<int> phoneEd25519Seed,
  }) : _relay = relay,
       _crypto = crypto,
       _machineDeviceId = machineDeviceId,
       _phoneDeviceId = phoneDeviceId,
       _agentEd25519PubB64 = agentEd25519PubB64,
       _phoneEd25519Seed = phoneEd25519Seed;

  final RelayService _relay;
  final CryptoService _crypto;
  final String _machineDeviceId;
  final String _phoneDeviceId;
  final String _agentEd25519PubB64;
  final List<int> _phoneEd25519Seed;

  ConnectionHandshake? _current;
  bool _aborted = false;

  @override
  Future<SessionKeys?> perform() async {
    if (_aborted) return null;
    final hs = _current = ConnectionHandshake(
      relay: _relay,
      crypto: _crypto,
      machineDeviceId: _machineDeviceId,
      phoneDeviceId: _phoneDeviceId,
      agentEd25519PubB64: _agentEd25519PubB64,
      phoneEd25519Seed: _phoneEd25519Seed,
    );
    try {
      return await hs.run();
    } finally {
      if (identical(_current, hs)) _current = null;
    }
  }

  @override
  void abort() {
    _aborted = true;
    _current?.cancel();
    _current = null;
  }
}
