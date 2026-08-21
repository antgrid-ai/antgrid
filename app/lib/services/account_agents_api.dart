import 'dart:convert';
import 'package:http/http.dart' as http;

class InventoryAgent {
  final String deviceUuid;
  final String displayName;
  final String platform;
  final String ed25519Pub; // base64
  final String? relayUrl;
  final DateTime? lastSeenAt;
  final String? machineName;

  InventoryAgent({
    required this.deviceUuid,
    required this.displayName,
    required this.platform,
    required this.ed25519Pub,
    this.relayUrl,
    this.lastSeenAt,
    this.machineName,
  });

  factory InventoryAgent.fromJson(Map<String, dynamic> j) => InventoryAgent(
    deviceUuid: j['deviceUuid'] as String,
    displayName: j['displayName'] as String,
    platform: j['platform'] as String,
    ed25519Pub: j['ed25519Pub'] as String,
    relayUrl: j['relayUrl'] as String?,
    lastSeenAt: j['lastSeenAt'] != null
        ? DateTime.parse(j['lastSeenAt'] as String)
        : null,
    machineName: j['machineName'] as String?,
  );
}

class AccountAgentsApi {
  final String baseUrl;
  final Future<String?> Function() sessionCookieProvider;
  final http.Client _http;

  AccountAgentsApi({
    required this.baseUrl,
    required this.sessionCookieProvider,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Future<List<InventoryAgent>> listAgents() async {
    // [cookie] is the full session cookie `name=value` pair (see AuthStorage);
    // replay it verbatim so the name matches what the server reads back
    // (`__Secure-`-prefixed over https) — a bare name is silently ignored.
    final cookie = await sessionCookieProvider();
    if (cookie == null) throw Exception('Not signed in');
    final res = await _http.get(
      Uri.parse('$baseUrl/account/agents'),
      headers: {'cookie': cookie},
    );
    if (res.statusCode == 401) throw Exception('Not signed in');
    if (res.statusCode != 200) {
      throw Exception('Inventory fetch failed: ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (j['agents'] as List).cast<Map<String, dynamic>>();
    return list.map(InventoryAgent.fromJson).toList();
  }
}
