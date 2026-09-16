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

const _transportMode = String.fromEnvironment(
  'ANTGRID_PEER_TRANSPORT',
  defaultValue: 'websocket',
);
PeerTransportMode get configuredPeerTransportMode => switch (_transportMode) {
  'iroh-preferred' => PeerTransportMode.irohPreferred,
  'iroh-only' when !kReleaseMode => PeerTransportMode.irohOnly,
  _ => PeerTransportMode.websocket,
};

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

class SelectedPeerLink {
  const SelectedPeerLink(this.link, {required this.independent});
  final PeerLink link;
  final bool independent;
}

class PeerRuntime {
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
      request: (method, path, body) async {
        final String token;
        try {
          token = await mintToken();
        } on DeviceRevokedException {
          throw const PeerAuthorizationDenied();
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
                    : _http.post(uri, headers: headers, body: jsonEncode(body)))
                .timeout(const Duration(seconds: 15));
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const PeerAuthorizationDenied();
        }
        if (response.statusCode == 409) {
          throw const PeerSelectionFailure('STALE_ENROLLMENT', terminal: true);
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError('Peer authorization HTTP ${response.statusCode}');
        }
        try {
          return jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          throw const FormatException('Invalid peer authorization response');
        }
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
  String? _nativeRelayPolicy;
  Future<bool>? _resuming;
  int _users = 0;
  bool _disposed = false;

  void retain() {
    _users++;
    lease.startRefreshing();
  }

  void release() {
    if (_users > 0) _users--;
    if (_users == 0) lease.stopRefreshing();
  }

  void notePolicyGeneration(BigInt generation) =>
      lease.notePolicyGeneration(generation);
  void invalidate() => lease.invalidate();
  Future<bool> resume() =>
      _resuming ??= lease.refreshFresh().whenComplete(() => _resuming = null);

  AuthorizationSnapshot _currentSnapshot() {
    final snapshot = lease.snapshot;
    if (_disposed || snapshot == null) {
      throw const PeerSelectionFailure('LEASE_EXPIRED', terminal: false);
    }
    return snapshot;
  }

  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);
  Future<void> _prepare() async {
    if (_disposed) throw const PeerSelectionFailure('DISPOSED', terminal: true);
    if (!await lease.refresh()) {
      final error = lease.lastRefreshFailure;
      throw PeerSelectionFailure(
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
    if (snapshot.endpoint?.endpointId != id) {
      await enrollment.register(
        deviceSecret: _deviceSecret,
        endpointSecret: _endpointSecret,
        expectedGeneration: snapshot.registrationGeneration,
      );
      if (!await lease.refresh()) {
        final error = lease.lastRefreshFailure;
        throw PeerSelectionFailure(
          'AUTHORIZATION_UNAVAILABLE',
          terminal:
              error is PeerAuthorizationDenied || error is FormatException,
        );
      }
    }
    if (_currentSnapshot().endpoint?.endpointId != id) {
      throw const PeerSelectionFailure(
        'LOCAL_ENDPOINT_ROTATED',
        terminal: true,
      );
    }
  }

  Future<SelectedPeerLink> select({
    required PeerLinkSelector selector,
    required RelayService relay,
    required String machineDeviceId,
    required String machinePublicKey,
    PeerTransportMode? mode,
    Future<void>? centralReady,
  }) async {
    final requestTimer = Stopwatch()..start();
    final selectedMode = mode ?? configuredPeerTransportMode;
    final requestedTransport = selectedMode == PeerTransportMode.websocket
        ? 'relay'
        : 'iroh';
    void diagnostic(Map<String, Object?> event) => relay.netTap?.call(event);
    emitPeerLifecycle(
      diagnostic,
      'peer:connection-request',
      transport: requestedTransport,
      elapsedMs: 0,
    );
    await prepare();
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
      throw const PeerSelectionFailure('PEER_IDENTITY_DENIED', terminal: true);
    }
    if (peer.ed25519Pub != machinePublicKey) {
      throw const PeerSelectionFailure('PEER_KEY_MISMATCH', terminal: true);
    }
    final registration = peer.endpoint;
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
            endpointId: registration?.endpointId,
            generation: registration?.generation,
          );
    }

    final selected = await selector.select(
      diagnostic: diagnostic,
      mode: selectedMode,
      websocket: () async {
        await centralReady;
        return relay;
      },
      iroh: () async {
        if (registration == null) {
          throw const PeerSelectionFailure('LEGACY_PEER', terminal: false);
        }
        final native = await _nativeFor(_currentSnapshot().relayUrls);
        if (_disposed) {
          await native.close();
          throw const PeerSelectionFailure('DISPOSED', terminal: true);
        }
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
      throw PeerSelectionFailure(
        _disposed
            ? 'DISPOSED_AFTER_SELECTION'
            : 'AUTHORIZATION_CHANGED_DURING_SELECTION',
        terminal: true,
      );
    }
    return SelectedPeerLink(
      LeasedPeerLink(
        selected,
        lease,
        peerId: machineDeviceId,
        endpointId: registration?.endpointId,
        registrationGeneration: registration?.generation,
      ),
      independent: selected is IrohPeerLink,
    );
  }

  static String _relayPolicy(List<String> urls) =>
      (urls.toList()..sort()).join('\n');

  Future<NativeEndpointOwner> _nativeFor(List<String> urls) {
    final policy = _relayPolicy(urls);
    if (_native != null && _nativeRelayPolicy == policy) return _native!;
    final previous = _native;
    _nativeRelayPolicy = policy;
    late final Future<NativeEndpointOwner> pending;
    pending =
        (() async {
          if (previous != null) {
            try {
              await (await previous).close();
            } catch (_) {}
          }
          if (_disposed) {
            throw const PeerSelectionFailure('DISPOSED', terminal: true);
          }
          final native = await NativeEndpointOwner.create(
            enrollmentId: record.clientId,
            keyStore: _RecordEndpointKeyStore(record),
            approvedRelays: urls,
            initializeNative: _initializeBundledIroh,
          );
          if (_disposed || _nativeRelayPolicy != policy) {
            await native.close();
            throw const PeerSelectionFailure(
              'ENDPOINT_SUPERSEDED',
              terminal: true,
            );
          }
          return native;
        })().onError((Object error, StackTrace stack) {
          if (identical(_native, pending)) _native = null;
          Error.throwWithStackTrace(error, stack);
        });
    return _native = pending;
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
