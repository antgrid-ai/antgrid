import 'dart:convert';
import 'package:http/http.dart' as http;
import 'cookie_api_client.dart';
import 'devices_api_contract.dart';

class DeviceSummary {
  DeviceSummary({
    required this.id,
    required this.deviceId,
    required this.kind,
    required this.platform,
    required this.displayName,
  });

  final String id;
  final String deviceId;
  final String kind;
  final String platform;
  final String displayName;
}

class DevicesApi extends CookieApiClient implements DevicesApiCreator {
  DevicesApi({
    required super.licenseApiUrl,
    required super.cookieProvider,
    super.httpClient,
  });

  Future<List<DeviceSummary>> list() async {
    final cookie = await cookieProvider();
    if (cookie == null) return const [];
    final res = await client.get(
      Uri.parse('$licenseApiUrl/account/devices'),
      headers: {'cookie': cookie},
    );
    if (res.statusCode != 200) return const [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (body['devices'] as List).cast<Map<String, dynamic>>();
    return list
        .map(
          (d) => DeviceSummary(
            id: d['id'] as String,
            deviceId: d['device_id'] as String,
            kind: d['kind'] as String,
            platform: d['platform'] as String,
            displayName: d['display_name'] as String,
          ),
        )
        .toList();
  }

  Future<bool> revoke(String id) async {
    final cookie = await cookieProvider();
    if (cookie == null) return false;
    final res = await client.delete(
      Uri.parse('$licenseApiUrl/account/devices/$id'),
      headers: {'cookie': cookie},
    );
    return res.statusCode == 200;
  }

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
    String? kind,
  }) async {
    final cookie = await cookieProvider();
    if (cookie == null) {
      throw ProvisioningException('AUTH', 'Not signed in');
    }
    http.Response res;
    try {
      res = await client.post(
        Uri.parse('$licenseApiUrl/account/devices'),
        headers: {'content-type': 'application/json', 'cookie': cookie},
        body: jsonEncode({
          'deviceUuid': deviceUuid,
          'ed25519Pub': ed25519Pub,
          'x25519Pub': x25519Pub,
          'platform': platform,
          'displayName': displayName,
          // Omitted (not null) when unset so the server keeps deriving the kind
          // from the platform.
          'kind': ?kind,
        }),
      );
    } catch (e) {
      throw ProvisioningException('NETWORK', e.toString());
    }
    if (res.statusCode == 401) {
      throw ProvisioningException('AUTH', 'Session expired');
    }
    if (res.statusCode == 402) {
      if (_isAppDeviceCapBody(res.body)) {
        // NOT a paid gate: `appDeviceLimit` is an abuse ceiling on phones and
        // controllers that pricing never mentions, so the only remedy is to
        // remove an app device — upgrading can never clear it. The
        // APP_DEVICE_CAP body is built in web/src/routes/devices.ts; the
        // two-axis model is web/CLAUDE.md (the security-invariants paragraph).
        final cap = _deviceCapFromBody(res.body, kind: DeviceCapKind.appDevice);
        throw ProvisioningException('APP_DEVICE_CAP', cap.message, cap: cap);
      }
      // Everything else, an unparseable body included: the paid axis, how many
      // machines the account may run an agent on. It is the safer fallback now
      // that it is also the only cap a server can raise — a mislabelled worker
      // rejection still offers freeing a slot, while a mislabelled app-device
      // rejection would hide the upgrade path the user actually needs.
      final cap = _deviceCapFromBody(res.body, kind: DeviceCapKind.worker);
      throw ProvisioningException('WORKER_CAP', cap.message, cap: cap);
    }
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ProvisioningException(
        'UNKNOWN',
        'POST /account/devices returned ${res.statusCode}: ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return CreatedDevice(
      deviceUuid: body['deviceUuid'] as String,
      clientId: body['clientId'] as String,
      clientSecret: body['clientSecret'] as String?,
    );
  }
}

class CreatedDevice {
  CreatedDevice({
    required this.deviceUuid,
    required this.clientId,
    this.clientSecret,
  });
  final String deviceUuid;
  final String clientId;

  /// null when an idempotent retry returned an already-provisioned device.
  final String? clientSecret;
}

class ProvisioningException implements Exception {
  ProvisioningException(this.code, this.message, {this.cap});

  /// 'AUTH' | 'APP_DEVICE_CAP' | 'WORKER_CAP' | 'NETWORK' | 'UNKNOWN'
  final String code;
  final String message;

  /// Populated only for the two cap codes: the limit and the devices already
  /// registered, so the UI can offer to revoke one. Null otherwise.
  final DeviceCapInfo? cap;

  @override
  String toString() => 'ProvisioningException($code): $message';
}

/// Which of the two independent caps a 402 rejected against. They share a
/// payload shape and a remediation dialog but not a remedy: [appDevice] is the
/// abuse ceiling on phones and controllers (free a slot), [worker] is the paid
/// axis on agent machines (free a slot OR upgrade).
enum DeviceCapKind { appDevice, worker }

/// One device already registered against the account, as carried in a 402
/// cap response body. Lighter than [DeviceSummary] — the cap payload only
/// includes the fields needed to identify and revoke a device.
class CappedDevice {
  CappedDevice({
    required this.id,
    required this.deviceId,
    required this.displayName,
  });
  final String id;
  final String deviceId;
  final String displayName;
}

/// Structured detail of a cap rejection (HTTP 402 `APP_DEVICE_CAP`/`WORKER_CAP`).
class DeviceCapInfo {
  DeviceCapInfo({
    required this.message,
    required this.kind,
    this.limit,
    this.devices = const [],
  });

  /// Human, actionable message. Always leads with freeing a slot — for
  /// [DeviceCapKind.appDevice] that is the only remedy there will ever be.
  final String message;
  final DeviceCapKind kind;
  final int? limit;
  final List<CappedDevice> devices;
}

/// True only when a 402 body explicitly names the app-device ceiling. Anything
/// else — including a body that doesn't parse — is treated as the worker cap by
/// the caller, so the narrower, non-upgradable copy is never guessed at.
bool _isAppDeviceCapBody(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> &&
        decoded['error'] == 'APP_DEVICE_CAP';
  } catch (_) {
    return false;
  }
}

/// Parse a 402 cap body into [DeviceCapInfo]. Defensive: a body that doesn't
/// parse (or lacks the fields) still yields a usable generic cap notice rather
/// than masking the 402 as an opaque failure.
DeviceCapInfo _deviceCapFromBody(
  String body, {
  required DeviceCapKind kind,
}) {
  int? limit;
  var devices = const <CappedDevice>[];
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final l = decoded['limit'];
      if (l is num) limit = l.toInt();
      final ds = decoded['devices'];
      if (ds is List) {
        // Read each field only when it is actually a String. A throwing cast
        // (`123 as String?` throws in Dart) on one stray field would otherwise
        // abort the whole parse and drop EVERY device — defeating the purpose
        // of the remediation list. A bad field degrades only its own row.
        String str(Object? v) => v is String ? v : '';
        devices = ds
            .whereType<Map<String, dynamic>>()
            .map((d) {
              final name = str(d['display_name']).trim();
              return CappedDevice(
                id: str(d['id']),
                deviceId: str(d['device_id']),
                displayName: name.isEmpty ? 'Unnamed device' : name,
              );
            })
            .where((d) => d.id.isNotEmpty)
            .toList(growable: false);
      }
    }
  } catch (_) {
    // Fall through to the generic message below.
  }
  final message = switch ((kind, limit)) {
    (DeviceCapKind.worker, null) =>
      'You are using all of your worker machines — sign one out to add this one.',
    // Free allows exactly one machine, so the singular is the case a buyer
    // actually meets — "all 1 worker machines" is the copy they would see.
    (DeviceCapKind.worker, 1) =>
      'You are using your only worker machine — sign it out to add this one.',
    (DeviceCapKind.worker, final l) =>
      'You are using all $l worker machines — sign one out to add this one.',
    (DeviceCapKind.appDevice, null) =>
      'Device limit reached. Remove a device to register this one.',
    (DeviceCapKind.appDevice, final l) =>
      'Device limit reached ($l/$l). Remove a device to register this one.',
  };
  return DeviceCapInfo(
    message: message,
    kind: kind,
    limit: limit,
    devices: devices,
  );
}
