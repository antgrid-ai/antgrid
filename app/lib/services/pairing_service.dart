import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../analytics/analytics_service.dart';
import '../analytics/events.dart';
import '../models/qr_payload.dart';
import '../storage/recent_agents_store.dart';
import 'account_agents_api.dart';
import 'keychain_device_store.dart';
import 'phone_identity.dart';
import '../util/device_id.dart';
import '../util/secure_nonce.dart';

// PairException moved to the relay client (shared with the pure-Dart eval
// client). Re-exported so existing `import '.../pairing_service.dart'` callers
// keep resolving it from the same path.
export 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show PairException;

/// The pair-request's own timeout — the relay expires the pending pair past its
/// `deadline`, and the phone stops waiting for approval at the same horizon.
const Duration _kPairTimeout = Duration(seconds: 30);

/// First-pair flow:
///   QR -> ensure phone keypair -> connect (hello) -> pair-request ->
///   verify signed pair-approval -> persist `RecentAgent`.
///
/// Reconnect flow (no QR):
///   load RecentAgent -> ensure phone keypair -> connect -> pair-request (no
///   pairCode; agent recognizes via paired-phones.json) -> verify approval.
///
/// v3: pairing is MACHINE-level — one grant per (machine, phone-key) lifetime,
/// created over the machine's single socket. Pairing authorizes the phone via
/// the agent's signed pair-approval; the per-message E2E channel is then
/// established by [MachineSession]'s transcript-signed handshake.
class PairingService {
  final RelayService _relay;
  final PhoneIdentity _phoneIdentity;
  final RecentAgentsStore _recentAgentsStore;

  /// The bare machine `deviceUuid` this service pairs with — the pair-request's
  /// `agentDeviceId`, the routing target, and the machine-level trust anchor
  /// key's namespace. There is no sub-deviceId in v3.
  final String _machineDeviceId;

  /// Provider for the phone's license JWT — REQUIRED for every app `hello` in
  /// v3 (design §4.2). Defaults to `null` (tests that don't thread tokens).
  final Future<String?> Function()? tokenProvider;

  /// Provider for the app's per-launch relay epoch (single global counter,
  /// design §6.3). Defaults to a wall-clock fallback when absent.
  final Future<int> Function()? epochProvider;

  /// Source of the provisioned account device key used to sign the
  /// account-membership proof attached to same-account [autoOpen] requests.
  final KeychainDeviceStore? _deviceStore;

  final Random? _random;
  final AnalyticsService? _analytics;

  PairingService({
    required RelayService relay,
    required PhoneIdentity phoneIdentity,
    required RecentAgentsStore recentAgentsStore,
    required String registrationId,
    Random? random,
    this.tokenProvider,
    this.epochProvider,
    KeychainDeviceStore? deviceStore,
    AnalyticsService? analytics,
  }) : _relay = relay,
       _phoneIdentity = phoneIdentity,
       _recentAgentsStore = recentAgentsStore,
       _machineDeviceId = baseDeviceUuid(registrationId),
       _deviceStore = deviceStore,
       _random = random,
       _analytics = analytics;

  /// The licenseToken last passed to a successful `_relay.connect`. We re-use
  /// the existing WS only when the token a caller wants to present matches what
  /// the relay already bound at hello (its `userId` is set once and cannot be
  /// re-stamped on the same connection).
  String? _lastLicenseToken;
  bool _lastLicenseTokenSet = false;

  int _deadlineMs() =>
      DateTime.now().add(_kPairTimeout).millisecondsSinceEpoch;

  /// Run the full QR-driven first-pair flow.
  Future<RecentAgent> pairWithAgent(
    QrPayload qr,
    DeviceIdentity identity, {
    String? label,
  }) async {
    final kp = await _phoneIdentity.ensureKeypair(_machineDeviceId);
    final phoneDeviceId = identity.deviceId;
    final nonce = secureNonceB64(rng: _random);
    final agentEd25519PubkeyB64 = base64.encode(qr.agentEd25519PublicKey);
    final requestedAt = DateTime.now().toUtc().toIso8601String();
    final deadline = _deadlineMs();
    final phoneSignature = await signPairRequest(
      agentDeviceId: _machineDeviceId,
      phonePubkey: kp.pubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      requestedAt: requestedAt,
      privSeed: kp.privSeed,
    );

    final token = await tokenProvider?.call();
    await _ensureRelayConnected(qr.relayUrl, identity, licenseToken: token);

    final approval = await _awaitAndVerifyApproval(
      agentEd25519PubkeyB64: agentEd25519PubkeyB64,
      agentDeviceId: _machineDeviceId,
      phonePubkey: kp.pubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      sendRequest: () => _relay.requestPair(
        agentDeviceId: _machineDeviceId,
        phonePubkey: kp.pubkeyB64,
        phoneDeviceId: phoneDeviceId,
        nonce: nonce,
        requestedAt: requestedAt,
        deadline: deadline,
        phoneSignature: phoneSignature,
        pairCode: qr.pairCode,
        label: label,
      ),
    );

    final now = DateTime.now();
    final ra = RecentAgent(
      agentDeviceId: qr.agentDeviceId,
      agentLabel: qr.agentName,
      agentEd25519Pubkey: agentEd25519PubkeyB64,
      relayUrl: qr.relayUrl,
      phoneDeviceId: identity.deviceId,
      phoneEd25519Pubkey: kp.pubkeyB64,
      pairedAt: now,
      lastConnectedAt: now,
      hostMachineName: qr.hostMachineName,
    );
    await _recentAgentsStore.upsert(ra);
    assert(approval.expiresAt.isAfter(now.subtract(const Duration(days: 1))));
    return ra;
  }

  /// Reconnect to a previously-paired agent. Reuses the per-machine phone
  /// keypair; the agent recognizes us via paired-phones.json (no `pairCode`).
  /// Grants persist relay-side across phone reconnects (design §5.1), so this
  /// re-runs the pair-request only for the relay-restart recovery case.
  Future<RecentAgent> reconnect(RecentAgent ra, DeviceIdentity identity) async {
    final kp = await _phoneIdentity.ensureKeypair(_machineDeviceId);
    if (kp.pubkeyB64 != ra.phoneEd25519Pubkey) {
      throw PairException(
        'Phone keypair mismatch for agent — re-pair required',
      );
    }

    // Idempotent re-entry: the machine socket may already be paired.
    if (_relay.currentState.connectionState == RelayConnectionState.paired) {
      final updated = ra.copyWith(lastConnectedAt: DateTime.now());
      await _recentAgentsStore.upsert(updated);
      _analytics?.track(AnalyticsEvents.agentPaired,
          props: {'method': 'reconnect'});
      return updated;
    }

    final phoneDeviceId = identity.deviceId;
    final nonce = secureNonceB64(rng: _random);
    final requestedAt = DateTime.now().toUtc().toIso8601String();
    final deadline = _deadlineMs();
    final phoneSignature = await signPairRequest(
      agentDeviceId: _machineDeviceId,
      phonePubkey: kp.pubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      requestedAt: requestedAt,
      privSeed: kp.privSeed,
    );

    final token = await tokenProvider?.call();
    await _ensureRelayConnected(ra.relayUrl, identity, licenseToken: token);

    await _awaitAndVerifyApproval(
      agentEd25519PubkeyB64: ra.agentEd25519Pubkey,
      agentDeviceId: _machineDeviceId,
      phonePubkey: kp.pubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      sendRequest: () => _relay.requestPair(
        agentDeviceId: _machineDeviceId,
        phonePubkey: kp.pubkeyB64,
        phoneDeviceId: phoneDeviceId,
        nonce: nonce,
        requestedAt: requestedAt,
        deadline: deadline,
        phoneSignature: phoneSignature,
        label: ra.agentLabel,
      ),
    );

    final updated = ra.copyWith(lastConnectedAt: DateTime.now());
    await _recentAgentsStore.upsert(updated);
    _analytics?.track(AnalyticsEvents.agentPaired,
        props: {'method': 'reconnect'});
    return updated;
  }

  /// QR-less pairing for same-account agents (machine-level trust). The app
  /// attaches an account-membership proof (agent auto-approves only if it
  /// verifies against the account's enrolled app-device set) and verifies the
  /// agent's `pair-approval` against `agent.ed25519Pub` from `/account/agents`.
  Future<RecentAgent> autoOpen(
      InventoryAgent agent, DeviceIdentity identity) async {
    if (agent.relayUrl == null) {
      throw PairException(
        'Agent has no relayUrl — host has not enabled mobile access',
      );
    }
    final kp = await _phoneIdentity.ensureKeypair(_machineDeviceId);
    final token = await tokenProvider?.call();

    // Idempotent re-entry: the machine socket may already be paired. Gate reuse
    // on the bound token still matching; on a token change fall through so the
    // socket is dropped and reconnected to rebind the userId.
    if (_relay.currentState.connectionState == RelayConnectionState.paired &&
        _lastLicenseTokenSet &&
        _lastLicenseToken == token) {
      final ra = _recentAgentFromInventory(agent, identity, kp.pubkeyB64);
      await _recentAgentsStore.upsert(ra);
      _analytics?.track(AnalyticsEvents.agentPaired,
          props: {'method': 'same_account'});
      return ra;
    }

    final phoneDeviceId = identity.deviceId;
    final nonce = secureNonceB64(rng: _random);
    final requestedAt = DateTime.now().toUtc().toIso8601String();
    final deadline = _deadlineMs();
    final phoneSignature = await signPairRequest(
      agentDeviceId: _machineDeviceId,
      phonePubkey: kp.pubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      requestedAt: requestedAt,
      privSeed: kp.privSeed,
    );

    final device = await _deviceStore?.read();
    if (device == null) {
      throw PairException('No provisioned account device — sign in first');
    }
    final rawPriv = base64.decode(device.ed25519Priv);
    final seed = rawPriv.length == 32 ? rawPriv : rawPriv.sublist(0, 32);
    final membershipSig = await signAccountMembership(
      agentDeviceId: _machineDeviceId,
      phoneDeviceId: phoneDeviceId,
      phonePubkey: kp.pubkeyB64,
      accountDevicePubkey: device.ed25519Pub,
      nonce: nonce,
      accountDevicePrivSeed: seed,
    );

    await _ensureRelayConnected(agent.relayUrl!, identity, licenseToken: token);

    final approval = await _awaitAndVerifyApproval(
      agentEd25519PubkeyB64: agent.ed25519Pub,
      agentDeviceId: _machineDeviceId,
      phonePubkey: kp.pubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      sendRequest: () => _relay.requestPair(
        agentDeviceId: _machineDeviceId,
        phonePubkey: kp.pubkeyB64,
        phoneDeviceId: phoneDeviceId,
        nonce: nonce,
        requestedAt: requestedAt,
        deadline: deadline,
        phoneSignature: phoneSignature,
        accountDevicePubkey: device.ed25519Pub,
        accountMembershipSig: membershipSig,
        label: agent.displayName,
      ),
    );

    final ra = _recentAgentFromInventory(agent, identity, kp.pubkeyB64);
    await _recentAgentsStore.upsert(ra);
    assert(
      approval.expiresAt.isAfter(ra.pairedAt.subtract(const Duration(days: 1))),
    );
    _analytics?.track(AnalyticsEvents.agentPaired,
        props: {'method': 'same_account'});
    return ra;
  }

  RecentAgent _recentAgentFromInventory(
    InventoryAgent agent,
    DeviceIdentity identity,
    String phoneEd25519PubkeyB64,
  ) {
    final now = DateTime.now();
    return RecentAgent(
      agentDeviceId: agent.deviceUuid,
      agentLabel: agent.displayName,
      agentEd25519Pubkey: agent.ed25519Pub,
      relayUrl: agent.relayUrl!,
      phoneDeviceId: identity.deviceId,
      phoneEd25519Pubkey: phoneEd25519PubkeyB64,
      pairedAt: now,
      lastConnectedAt: now,
      hostMachineName: agent.machineName,
    );
  }

  /// Arms approval/rejection/error subscriptions, sends the pair-request, races
  /// approval/rejection/typed-error/timeout, and verifies the approval sig.
  ///
  /// Typed errors are classified off [RelayService.errorStream] (the Dart client
  /// cannot read WS close codes): a frame is ours when `ref == nonce` (or when
  /// `ref` is absent, falling back to the pair-only codes). A retryable
  /// `AGENT_OFFLINE` re-sends the pair-request on the SAME still-open socket —
  /// riding out the project core's fire-and-forget slot registration — rather
  /// than reconnecting. The bare-close fallback covers genuine transport drops.
  Future<PairApprovalMessage> _awaitAndVerifyApproval({
    required String agentEd25519PubkeyB64,
    required String agentDeviceId,
    required String phonePubkey,
    required String phoneDeviceId,
    required String nonce,
    required void Function() sendRequest,
    int agentOfflineRetries = 8,
    Duration agentOfflineDelay = const Duration(milliseconds: 500),
  }) async {
    final completer = Completer<PairApprovalMessage>();
    late StreamSubscription<PairApprovalMessage> approvalSub;
    late StreamSubscription<PairRejectedMessage> rejectedSub;
    late StreamSubscription<ErrorMessage> errorSub;
    late StreamSubscription<AppState> stateSub;
    var offlineRetries = 0;
    Timer? retryTimer;

    void classifyError(ErrorMessage err) {
      if (completer.isCompleted) return;
      // Only errors pertaining to THIS pair-request: `ref` echoes the nonce
      // (fall back to pair-only codes when the relay omits ref).
      final pertains = err.ref == null || err.ref == nonce;
      if (!pertains) return;
      switch (err.code) {
        case 'AGENT_OFFLINE':
          if (offlineRetries >= agentOfflineRetries) {
            completer.completeError(
              PairException('Agent offline', agentOffline: true),
            );
            return;
          }
          offlineRetries++;
          retryTimer?.cancel();
          retryTimer = Timer(agentOfflineDelay, () {
            if (!completer.isCompleted) sendRequest();
          });
          break;
        case 'EXPIRED':
          completer.completeError(
            PairException('Pair request expired', agentOffline: true),
          );
          break;
        case 'PAIR_REJECTED':
        case 'UNKNOWN_PHONE':
        case 'PAIRING_WINDOW_CLOSED':
        case 'NONCE_MISMATCH':
        case 'APPROVAL_EXPIRED':
          completer.completeError(PairException('Pair rejected: ${err.code}'));
          break;
        default:
          // Other retryable errors leave the socket open; terminal ones surface
          // via the disconnect handler below.
          break;
      }
    }

    // A relay-initiated close mid-pairing surfaces ONLY as a connection-state
    // transition (the Dart WebSocketChannel can't read the close code).
    void failOnClose(AppState s) {
      if (completer.isCompleted) return;
      if (s.connectionState != RelayConnectionState.disconnected) return;
      final code = s.errorCode;
      if (code != null && code.isNotEmpty) {
        completer.completeError(
          PairException('Relay closed the connection: $code'),
        );
      } else {
        completer.completeError(
          PairException(
            'Agent offline — relay closed the connection before approval',
            agentOffline: true,
          ),
        );
      }
    }

    approvalSub = _relay.pairApprovalStream.listen((approval) {
      if (completer.isCompleted) return;
      if (approval.phonePubkey != phonePubkey) return;
      if (approval.phoneDeviceId != phoneDeviceId) return;
      if (approval.nonce != nonce) return;
      completer.complete(approval);
    });
    rejectedSub = _relay.pairRejectedStream.listen((rej) {
      if (completer.isCompleted) return;
      if (rej.phonePubkey != phonePubkey) return;
      completer.completeError(PairException('Pair rejected: ${rej.reason}'));
    });
    errorSub = _relay.errorStream.listen(classifyError);
    stateSub = _relay.stateStream.listen(failOnClose);

    try {
      if (_relay.currentState.connectionState ==
          RelayConnectionState.disconnected) {
        failOnClose(_relay.currentState);
      } else {
        sendRequest();
      }

      final approval = await completer.future.timeout(
        _kPairTimeout,
        onTimeout: () {
          throw PairException('Pair request timed out');
        },
      );

      final ok = await verifyPairApproval(
        agentEd25519PubkeyB64: agentEd25519PubkeyB64,
        agentDeviceId: agentDeviceId,
        phonePubkey: phonePubkey,
        phoneDeviceId: phoneDeviceId,
        nonce: nonce,
        expiresAt: approval.expiresAt.toIso8601String(),
        signatureB64: approval.signature,
      );
      if (!ok) {
        throw PairException('Pair approval signature invalid');
      }
      return approval;
    } finally {
      retryTimer?.cancel();
      await approvalSub.cancel();
      await rejectedSub.cancel();
      await errorSub.cancel();
      await stateSub.cancel();
    }
  }

  Future<void> _ensureRelayConnected(
    String relayUrl,
    DeviceIdentity identity, {
    String? licenseToken,
  }) async {
    final state = _relay.currentState.connectionState;
    final connected =
        state == RelayConnectionState.authenticated ||
        state == RelayConnectionState.paired ||
        state == RelayConnectionState.pairing;

    // Reuse the existing session ONLY when the token presented matches what the
    // relay already bound at hello (userId is set once and rejects a re-bind).
    if (connected &&
        _lastLicenseTokenSet &&
        _lastLicenseToken == licenseToken) {
      return;
    }
    if (connected) {
      _relay.disconnect();
      await _relay.stateStream
          .firstWhere(
            (s) => s.connectionState == RelayConnectionState.disconnected,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => _relay.currentState,
          );
    }

    if (_relay.currentState.connectionState != RelayConnectionState.connecting &&
        _relay.currentState.connectionState !=
            RelayConnectionState.authenticating) {
      final epoch = await (epochProvider?.call() ??
          Future.value(DateTime.now().millisecondsSinceEpoch ~/ 1000));
      // v3: licenseToken is mandatory for every app hello (design §4.2). A null
      // token can only occur pre-provisioning; the relay rejects it, surfacing
      // as a terminal close the pairing flow reports.
      await _relay.connect(
        relayUrl,
        identity,
        licenseToken: licenseToken ?? '',
        epoch: epoch,
      );
      _lastLicenseToken = licenseToken;
      _lastLicenseTokenSet = true;
    }

    final next = await _relay.stateStream
        .firstWhere(
          (s) =>
              s.connectionState == RelayConnectionState.authenticated ||
              s.connectionState == RelayConnectionState.paired ||
              s.connectionState == RelayConnectionState.disconnected,
        )
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw PairException('Relay connect timed out');
          },
        );

    if (next.connectionState == RelayConnectionState.disconnected) {
      throw PairException('Relay disconnected: ${next.error ?? 'unknown'}');
    }
  }

  /// Sever the grant and disconnect the socket.
  void disconnect() {
    final currentState = _relay.currentState.connectionState;
    if (currentState == RelayConnectionState.paired) {
      _relay.unpair();
    }
    _relay.disconnect();
  }
}
