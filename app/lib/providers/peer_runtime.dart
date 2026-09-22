import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../connection/peer_runtime.dart';
import '../connection/peer_runtime_owner.dart';
import '../services/keychain_device_store.dart';
import '../services/devices_api.dart' show ProvisioningException;
import '../util/detached.dart';
import 'auth.dart';
import 'connection_identity.dart';
import 'provider_retry.dart';

final class PeerRuntimeRequest {
  const PeerRuntimeRequest({
    required this.record,
    required this.licenseApiUrl,
    required this.mintToken,
  });

  final DeviceRecord record;
  final String licenseApiUrl;
  final Future<String> Function() mintToken;
}

typedef AppPeerRuntimeOwner = PeerRuntimeOwner<PeerRuntime, PeerRuntimeRequest>;

final peerRuntimeOwnerProvider = Provider<AppPeerRuntimeOwner>((ref) {
  final owner = AppPeerRuntimeOwner(
    create: (request) => PeerRuntime(
      record: request.record,
      licenseApiUrl: request.licenseApiUrl,
      mintToken: request.mintToken,
    ),
    dispose: (runtime) async {
      if (await runtime.dispose()) {
        return const PeerRuntimeCleanupResult.complete();
      }
      return PeerRuntimeCleanupResult.incomplete(
        StateError('native endpoint ownership remains unresolved'),
      );
    },
  );
  ref.onDispose(() {
    detached('PeerRuntimeOwner', 'clear', () async {
      final result = await owner.clear();
      if (!result.complete) {
        throw PeerRuntimeOwnerLockedException(owner.cleanupFailure!);
      }
    });
  });
  return owner;
});

final peerRuntimeProvider = FutureProvider<PeerRuntime>((ref) async {
  final record = await ref.watch(connectionDeviceRecordProvider.future);
  if (record.endpointSecret == null) {
    throw ProvisioningException(
      'AUTH',
      'A protected endpoint key is required for remote connections',
    );
  }
  // Resume refreshes the minter provider without changing enrollment. Existing
  // machine connections retain this runtime, so that refresh must not dispose it.
  final minter = await ref.read(connectionTokenMinterProvider.future);
  if (minter == null) {
    throw ProvisioningException(
      'AUTH',
      'Device credentials are required for remote connections',
    );
  }
  if (!ref.mounted) {
    throw StateError('Peer runtime provider disposed during provisioning');
  }
  final endpointSecret = record.endpointSecret!;
  return ref
      .read(peerRuntimeOwnerProvider)
      .obtain(
        PeerRuntimeIdentity(
          accountId: record.userId,
          enrollmentId: record.clientId,
          endpointSecret: endpointSecret,
        ),
        PeerRuntimeRequest(
          record: record,
          licenseApiUrl: ref.watch(licenseApiUrlProvider),
          mintToken: minter.mint,
        ),
      );
}, retry: noProviderRetry);
