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
      if (_isWorkerCapBody(res.body)) {
        // The paid axis: how many machines the account may run an agent on.
        // Registering a `kind:"agent"` record consumes a worker slot, so this
        // rejection CAN be answered by upgrading — the opposite remedy to
        // DEVICE_CAP below, which is why the two codes must stay distinct.
        final cap = _deviceCapFromBody(res.body, kind: DeviceCapKind.worker);
        throw ProvisioningException('WORKER_CAP', cap.message, cap: cap);
      }
      // The other axis, and NOT a paid gate: `deviceLimit` is a flat fair-use
      // registration ceiling, identical across ALL tiers including free, so the
      // only remedy is to remove a device — upgrading can never clear it. The
      // DEVICE_CAP body is built in web/src/routes/devices.ts; the two-axis
      // model is web/CLAUDE.md (the security-invariants paragraph).
      final cap = _deviceCapFromBody(res.body);
      throw ProvisioningException('DEVICE_CAP', cap.message, cap: cap);
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

  /// 'AUTH' | 'DEVICE_CAP' | 'WORKER_CAP' | 'NETWORK' | 'UNKNOWN'
  final String code;
  final String message;

  /// Populated only for the two cap codes: the limit and the devices already
  /// registered, so the UI can offer to revoke one. Null otherwise.
  final DeviceCapInfo? cap;

  @override
  String toString() => 'ProvisioningException($code): $message';
}

/// Which of the two independent caps a 402 rejected against. They share a
/// payload shape and a remediation dialog but not a remedy: [device] is the
/// flat fair-use ceiling (free a slot), [worker] is the paid axis (free a slot
/// OR upgrade).
enum DeviceCapKind { device, worker }

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

/// Structured detail of a cap rejection (HTTP 402 `DEVICE_CAP`/`WORKER_CAP`).
class DeviceCapInfo {
  DeviceCapInfo({
    required this.message,
    this.kind = DeviceCapKind.device,
    this.limit,
    this.devices = const [],
  });

  /// Human, actionable message. Always leads with freeing a slot — for
  /// [DeviceCapKind.device] that is the only remedy there will ever be.
  final String message;
  final DeviceCapKind kind;
  final int? limit;
  final List<CappedDevice> devices;
}

/// True when a 402 body names the worker cap rather than the device cap. A body
/// that doesn't parse falls back to the device cap: it is the older, stricter
/// copy, so mislabelling never promises an upgrade path that isn't there.
bool _isWorkerCapBody(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> && decoded['error'] == 'WORKER_CAP';
  } catch (_) {
    return false;
  }
}

/// Parse a 402 cap body into [DeviceCapInfo]. Defensive: a body that doesn't
/// parse (or lacks the fields) still yields a usable generic cap notice rather
/// than masking the 402 as an opaque failure.
DeviceCapInfo _deviceCapFromBody(
  String body, {
  DeviceCapKind kind = DeviceCapKind.device,
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
      'You are using all of your workers — sign one out to add this machine.',
    (DeviceCapKind.worker, final l) =>
      'You are using all $l workers — sign one out to add this machine.',
    (DeviceCapKind.device, null) =>
      'Device limit reached. Remove a device to register this one.',
    (DeviceCapKind.device, final l) =>
      'Device limit reached ($l/$l). Remove a device to register this one.',
  };
  return DeviceCapInfo(
    message: message,
    kind: kind,
    limit: limit,
    devices: devices,
  );
}
