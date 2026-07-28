import 'dart:convert';
import 'package:http/http.dart' as http;

/// Posts this device's heartbeat to the account service so its `lastSeenAt`
/// shows real recency in the web Devices dashboard instead of staying null
/// forever. Mirrors `bridge/src/heartbeat.ts`; the app omits the agent-only
/// `mobileAccessEnabled`/`relayUrl`/`machineName` fields, which the endpoint
/// treats as optional and leaves untouched when absent (see
/// `web/src/routes/agents.ts`).
Future<bool> sendAccountHeartbeat({
  required String licenseApiUrl,
  required String token,
  required String deviceUuid,
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final base = licenseApiUrl.replaceAll(RegExp(r'/+$'), '');
    final res = await client.post(
      Uri.parse('$base/account/devices/me/heartbeat'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'deviceUuid': deviceUuid}),
    );
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    if (httpClient == null) client.close();
  }
}
