import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../connection/peer_runtime.dart';
import '../services/devices_api.dart' show ProvisioningException;
import '../util/detached.dart';
import 'auth.dart';
import 'connection_identity.dart';
import 'provider_retry.dart';

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
  final runtime = PeerRuntime(
    record: record,
    licenseApiUrl: ref.watch(licenseApiUrlProvider),
    mintToken: minter.mint,
  );
  ref.onDispose(() => detached('PeerRuntime', 'dispose', runtime.dispose));
  return runtime;
}, retry: noProviderRetry);
