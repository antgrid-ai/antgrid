import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:iroh_flutter/iroh_flutter.dart' as iroh;
import 'package:path/path.dart' as path;

import '../services/keychain_device_store.dart';
import '../services/license_token_minter.dart';

Future<void>? _bundledIrohInitialization;

Future<void> _initializeBundledIroh() {
  // A replacement account runtime can start while the prior endpoint is still
  // initializing. Upstream's idempotence flag does not serialize that window.
  return _bundledIrohInitialization ??= _loadBundledIroh().onError((
    Object error,
    StackTrace stack,
  ) {
    _bundledIrohInitialization = null;
    Error.throwWithStackTrace(error, stack);
  });
}

Future<void> _loadBundledIroh() {
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  if (Platform.isWindows) {
    return iroh.Iroh.init(
      libraryPath: path.join(executableDirectory, 'irohdart_ffi.dll'),
    );
  }
  if (Platform.isLinux) {
    return iroh.Iroh.init(
      libraryPath: path.join(executableDirectory, 'lib', 'libirohdart_ffi.so'),
    );
  }
  if (Platform.isAndroid) {
    return iroh.Iroh.init(libraryPath: 'libirohdart_ffi.so');
  }
  // Upstream has no public process-symbol-only initializer for Apple targets.
  // Its default searches disk first; Apple native rollout remains unqualified.
  return iroh.Iroh.init();
}

abstract interface class PeerConnector {
  void retain();
  void release();
  Future<bool> resume();
  void invalidate();
  void notePolicyGeneration(BigInt generation);
  Future<PeerLink> connect({
    required PeerConnectionAttempt attempt,
    required RelayService relay,
    required String machineDeviceId,
    required String machinePublicKey,
  });
}

class PeerRuntime implements PeerConnector {
  PeerRuntime({
    required this.record,
    required String licenseApiUrl,
    required Future<String> Function() mintToken,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       _endpointSecret = base64Decode(record.endpointSecret!),
       _deviceSecret = base64Decode(record.ed25519Priv) {
    enrollment = EndpointEnrollmentClient(
      accountId: record.userId,
      deviceId: record.deviceUuid,
      enrollmentId: record.clientId,
      request: (method, path, body) {
        var expired = false;
        return (() async {
          final String token;
          try {
            token = await mintToken();
          } on DeviceRevokedException {
            throw const PeerAuthorizationDenied();
          }
          if (expired || _disposed) {
            throw TimeoutException('Authorization request retired');
          }
          final uri = Uri.parse(
            '${licenseApiUrl.replaceAll(RegExp(r'/+$'), '')}$path',
          );
          final headers = {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          };
          final response =
              await (method == 'GET'
                      ? _http.get(uri, headers: headers)
                      : _http.post(
                          uri,
                          headers: headers,
                          body: jsonEncode(body),
                        ))
                  .timeout(const Duration(seconds: 15));
          if (response.statusCode == 401 || response.statusCode == 403) {
            throw const PeerAuthorizationDenied();
          }
          if (response.statusCode == 409) {
            throw const PeerConnectionFailure(
              'STALE_ENROLLMENT',
              terminal: true,
            );
          }
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw StateError('Peer authorization HTTP ${response.statusCode}');
          }
          try {
            return jsonDecode(response.body) as Map<String, dynamic>;
          } catch (_) {
            throw const FormatException('Invalid peer authorization response');
          }
        })().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            expired = true;
            throw const PeerConnectionFailure(
              'AUTHORIZATION_TIMEOUT',
              terminal: false,
              stage: PeerConnectionStage.authorization,
            );
          },
        );
      },
    );
    lease = AuthorizationLease(
      accountId: record.userId,
      deviceId: record.deviceUuid,
      enrollmentId: record.clientId,
      fetchSnapshot: enrollment.fetchSnapshot,
    );
  }
  final DeviceRecord record;
  final http.Client _http;
  final Uint8List _endpointSecret, _deviceSecret;
  late final EndpointEnrollmentClient enrollment;
  late final AuthorizationLease lease;
  Future<void>? _preparing;
  Future<NativeEndpointOwner>? _native;
  void Function()? _retireInitialization;
  String? _nativeRelayPolicy;
  Future<bool>? _resuming;
  int _users = 0;
  bool _disposed = false;

  @override
  void retain() {
    _users++;
    lease.startRefreshing();
  }

  @override
  void release() {
    if (_users > 0) _users--;
    if (_users == 0) lease.stopRefreshing();
  }

  @override
  void notePolicyGeneration(BigInt generation) =>
      lease.notePolicyGeneration(generation);
  @override
  void invalidate() => lease.invalidate();
  @override
  Future<bool> resume() =>
      _resuming ??= lease.refreshFresh().whenComplete(() => _resuming = null);

  AuthorizationSnapshot _currentSnapshot() {
    final snapshot = lease.snapshot;
    if (_disposed || snapshot == null) {
      throw const PeerConnectionFailure('LEASE_EXPIRED', terminal: false);
    }
    return snapshot;
  }

  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);
  Future<void> _prepare() async {
    if (_disposed) {
      throw const PeerConnectionFailure('DISPOSED', terminal: true);
    }
    if (!await lease.refresh()) {
      final error = lease.lastRefreshFailure;
      throw PeerConnectionFailure(
        'AUTHORIZATION_UNAVAILABLE',
        terminal: error is PeerAuthorizationDenied || error is FormatException,
      );
    }
    final key = await Ed25519().newKeyPairFromSeed(_endpointSecret);
    final pub = await key.extractPublicKey();
    final id = pub.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final snapshot = _currentSnapshot();
    if (snapshot.endpoint != null && snapshot.endpoint?.endpointId != id) {
      throw const PeerConnectionFailure(
        'LOCAL_ENDPOINT_ROTATED',
        terminal: true,
      );
    }
    if (snapshot.endpoint?.endpointId != id) {
      await enrollment.register(
        deviceSecret: _deviceSecret,
        endpointSecret: _endpointSecret,
        expectedGeneration: snapshot.registrationGeneration,
      );
      if (!await lease.refresh()) {
        final error = lease.lastRefreshFailure;
        throw PeerConnectionFailure(
          'AUTHORIZATION_UNAVAILABLE',
          terminal:
              error is PeerAuthorizationDenied || error is FormatException,
        );
      }
    }
    if (_currentSnapshot().endpoint?.endpointId != id) {
      throw const PeerConnectionFailure(
        'LOCAL_ENDPOINT_ROTATED',
        terminal: true,
      );
    }
  }

  @override
  Future<PeerLink> connect({
    required PeerConnectionAttempt attempt,
    required RelayService relay,
    required String machineDeviceId,
    required String machinePublicKey,
  }) async {
    final generation = attempt.generation;
    final requestTimer = Stopwatch()..start();
    const requestedTransport = 'iroh';
    void diagnostic(Map<String, Object?> event) => relay.netTap?.call(event);
    emitPeerLifecycle(
      diagnostic,
      'peer:connection-request',
      transport: requestedTransport,
      elapsedMs: 0,
    );
    await prepare();
    attempt.checkCurrent(generation);
    emitPeerLifecycle(
      diagnostic,
      'peer:authorization-ready',
      transport: requestedTransport,
      elapsedMs: requestTimer.elapsedMilliseconds,
    );
    AuthorizedPeer? peer;
    for (final value in _currentSnapshot().peers) {
      if (value.deviceId == machineDeviceId) peer = value;
    }
    if (peer == null) {
      throw const PeerConnectionFailure('PEER_IDENTITY_DENIED', terminal: true);
    }
    if (peer.ed25519Pub != machinePublicKey) {
      throw const PeerConnectionFailure('PEER_KEY_MISMATCH', terminal: true);
    }
    final registration = peer.endpoint;
    if (registration == null) {
      throw const PeerConnectionFailure(
        'PEER_ENDPOINT_REQUIRED',
        terminal: true,
      );
    }
    final local = _currentSnapshot().endpoint;
    final relayPolicy = _relayPolicy(_currentSnapshot().relayUrls);
    bool authorized() {
      final snapshot = lease.snapshot;
      return !_disposed &&
          snapshot != null &&
          snapshot.endpoint?.endpointId == local?.endpointId &&
          snapshot.endpoint?.generation == local?.generation &&
          _relayPolicy(snapshot.relayUrls) == relayPolicy &&
          snapshot.peers.any(
            (value) =>
                value.deviceId == machineDeviceId &&
                value.ed25519Pub == machinePublicKey,
          ) &&
          lease.permits(
            machineDeviceId,
            endpointId: registration.endpointId,
            generation: registration.generation,
          );
    }

    final native = await _nativeFor(_currentSnapshot().relayUrls);
    attempt.checkCurrent(generation);
    final selected = await attempt.connect(
      diagnostic: diagnostic,
      iroh: () async {
        return native.dial(
          endpointId: registration.endpointId,
          localDeviceId: relaySlotId(record.deviceUuid, machineDeviceId),
          peerDeviceId: machineDeviceId,
          authorized: authorized,
          diagnostic: (event) => relay.netTap?.call(event),
        );
      },
    );
    if (!authorized()) {
      await selected.close();
      throw PeerConnectionFailure(
        _disposed
            ? 'DISPOSED_AFTER_CONNECT'
            : 'AUTHORIZATION_CHANGED_DURING_CONNECT',
        terminal: true,
      );
    }
    return LeasedPeerLink(
      selected,
      lease,
      peerId: machineDeviceId,
      endpointId: registration.endpointId,
      registrationGeneration: registration.generation,
    );
  }

  static String _relayPolicy(List<String> urls) =>
      (urls.toList()..sort()).join('\n');

  Future<NativeEndpointOwner> _nativeFor(List<String> urls) async {
    final policy = _relayPolicy(urls);
    if (_native != null && _nativeRelayPolicy == policy) {
      return _awaitNative(_native!, _retireInitialization!);
    }
    final previous = _native;
    _retireInitialization?.call();
    var retired = false;
    void retire() => retired = true;
    _retireInitialization = retire;
    _nativeRelayPolicy = policy;
    late final Future<NativeEndpointOwner> pending;
    pending =
        (() async {
          if (previous != null) {
            NativeEndpointOwner? previousOwner;
            try {
              previousOwner = await previous;
            } catch (_) {}
            if (previousOwner != null) await previousOwner.close();
          }
          if (_disposed) {
            throw const PeerConnectionFailure('DISPOSED', terminal: true);
          }
          final native = await NativeEndpointOwner.create(
            enrollmentId: record.clientId,
            keyStore: _RecordEndpointKeyStore(record),
            approvedRelays: urls,
            initializeNative: _initializeBundledIroh,
          );
          if (_disposed || retired || _nativeRelayPolicy != policy) {
            await native.close();
            throw const PeerConnectionFailure(
              'SUPERSEDED',
              terminal: false,
              stage: PeerConnectionStage.initialization,
            );
          }
          return native;
        })().onError((Object error, StackTrace stack) {
          if (identical(_native, pending)) _native = null;
          Error.throwWithStackTrace(error, stack);
        });
    _native = pending;
    return _awaitNative(pending, retire);
  }

  Future<NativeEndpointOwner> _awaitNative(
    Future<NativeEndpointOwner> pending,
    void Function() retire,
  ) {
    return pending.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        retire();
        throw const PeerConnectionFailure(
          'ENDPOINT_INIT_TIMEOUT',
          terminal: false,
          stage: PeerConnectionStage.initialization,
        );
      },
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    lease.invalidate();
    _endpointSecret.fillRange(0, _endpointSecret.length, 0);
    _deviceSecret.fillRange(0, _deviceSecret.length, 0);
    _http.close();
    await lease.dispose();
    final native = _native;
    if (native != null) {
      try {
        await (await native).close();
      } catch (_) {}
    }
  }
}

class _RecordEndpointKeyStore implements EndpointKeyStore {
  _RecordEndpointKeyStore(this.record);
  final DeviceRecord record;
  @override
  Future<Uint8List?> read(String enrollmentId) async {
    if (enrollmentId != record.clientId) {
      throw StateError('Enrollment mismatch');
    }
    return base64Decode(record.endpointSecret!);
  }

  @override
  Future<void> write(String enrollmentId, Uint8List secret) async =>
      throw StateError('Endpoint keys are provisioned in the account keychain');
  @override
  Future<void> delete(String enrollmentId) async =>
      throw StateError('Device revocation owns account keychain deletion');
}
