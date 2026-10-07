import 'auth_service.dart';
import 'device_provisioning.dart';
import 'devices_api.dart';
import 'keychain_device_store.dart';

typedef RehostLocalProjects =
    Future<void> Function({required String from, required String to});

/// Owns the account-device provisioning transaction and its published result.
///
/// All dependencies are captured before an attempt starts, so callers never
/// need to carry a Riverpod or widget ref across an asynchronous boundary.
class ProvisioningCoordinator {
  ProvisioningCoordinator({
    required DeviceProvisioning provisioning,
    required KeychainDeviceStore store,
    required Future<CurrentUser?> Function() readCurrentUser,
    required String? Function() currentUserId,
    required Future<String> Function() readDisplayName,
    required Future<String?> Function() readLocalHostUuid,
    required Future<void> Function(String value) writeLocalHostUuid,
    required RehostLocalProjects rehostLocalProjects,
    required void Function() publishSuccess,
    required void Function(DeviceCapInfo? cap) publishDeviceCap,
    this.onProvisioningError,
    this.onUnexpectedError,
  }) : _provisioning = provisioning,
       _store = store,
       _readCurrentUser = readCurrentUser,
       _currentUserId = currentUserId,
       _readDisplayName = readDisplayName,
       _readLocalHostUuid = readLocalHostUuid,
       _writeLocalHostUuid = writeLocalHostUuid,
       _rehostLocalProjects = rehostLocalProjects,
       _publishSuccess = publishSuccess,
       _publishDeviceCap = publishDeviceCap;

  final DeviceProvisioning _provisioning;
  final KeychainDeviceStore _store;
  final Future<CurrentUser?> Function() _readCurrentUser;
  final String? Function() _currentUserId;
  final Future<String> Function() _readDisplayName;
  final Future<String?> Function() _readLocalHostUuid;
  final Future<void> Function(String value) _writeLocalHostUuid;
  final RehostLocalProjects _rehostLocalProjects;
  final void Function() _publishSuccess;
  final void Function(DeviceCapInfo? cap) _publishDeviceCap;
  final void Function(String logTag, ProvisioningException error)?
  onProvisioningError;
  final void Function(String logTag, Object error)? onUnexpectedError;

  Future<DeviceRecord>? _inFlight;
  String? _inFlightUserId;

  void clearDeviceCap() => _publishDeviceCap(null);

  /// Explicit sign-in/retry path. Both entry points publish identical results.
  Future<DeviceRecord> provisionSignedInUser(String userId) async {
    try {
      final record = await _ensureForUser(userId);
      if (_currentUserId() != userId) {
        throw ProvisioningException(
          'AUTH',
          'Account changed during provisioning',
        );
      }
      _publishDeviceCap(null);
      _publishSuccess();
      return record;
    } on ProvisioningException catch (error) {
      if (_currentUserId() == userId &&
          _isDeviceCap(error) &&
          error.cap != null) {
        _publishDeviceCap(error.cap);
      }
      rethrow;
    }
  }

  Future<DeviceRecord> retryCurrentUser() async {
    final user = await _readCurrentUser();
    if (user == null) {
      throw ProvisioningException('AUTH', 'Sign in required');
    }
    return provisionSignedInUser(user.userId);
  }

  /// Lazy callers need the record without publishing sign-in UI side effects.
  Future<DeviceRecord> ensureCurrentUserDeviceRecord() async {
    final user = await _readCurrentUser();
    if (user == null) {
      throw ProvisioningException('AUTH', 'Sign in required');
    }
    return _ensureForUser(user.userId);
  }

  Future<DeviceRecord?> resolveDeviceRecord({required String logTag}) async {
    DeviceRecord? device = await _store.read();
    if (device != null && device.endpointSecret != null) return device;
    try {
      final user = await _readCurrentUser();
      if (user != null) device = await _ensureForUser(user.userId);
    } on ProvisioningException catch (error) {
      onProvisioningError?.call(logTag, error);
    } catch (error) {
      onUnexpectedError?.call(logTag, error);
    }
    return device;
  }

  Future<DeviceRecord> _ensureForUser(String userId) async {
    final pending = _inFlight;
    if (pending != null) {
      if (_inFlightUserId == userId) return pending;
      try {
        await pending;
      } catch (_) {}
    }
    final attempt = _provisionAndPersist(userId);
    _inFlight = attempt;
    _inFlightUserId = userId;
    return attempt.whenComplete(() {
      if (identical(_inFlight, attempt)) {
        _inFlight = null;
        _inFlightUserId = null;
      }
    });
  }

  Future<DeviceRecord> _provisionAndPersist(String userId) async {
    final existing = await _readLocalHostUuid();
    final record = await _provisioning.ensureProvisioned(
      userId: userId,
      displayName: await _readDisplayName(),
      existingDeviceUuid: existing,
    );
    if (_currentUserId() != userId) {
      throw ProvisioningException(
        'AUTH',
        'Account changed during provisioning',
      );
    }
    final outgoing = await _readLocalHostUuid();
    if (outgoing != record.deviceUuid) {
      await _writeLocalHostUuid(record.deviceUuid);
      if (outgoing != null) {
        await _rehostLocalProjects(from: outgoing, to: record.deviceUuid);
      }
    }
    return record;
  }
}

bool _isDeviceCap(ProvisioningException error) =>
    error.code == 'APP_DEVICE_CAP' || error.code == 'WORKER_CAP';
