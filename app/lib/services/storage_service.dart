import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../config/storage_scope.dart';

class StorageService {
  final FlutterSecureStorage _storage;

  StorageService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<List<PairedAgent>> loadPairedAgents() async {
    final raw = await _storage.read(key: scopedStorageKey('paired_agents'));
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => PairedAgent(
              relayUrl: e['relayUrl'] as String,
              agentDeviceId: e['agentDeviceId'] as String,
              agentName: e['agentName'] as String,
              // Session keys are per-connection and never persisted (v2).
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePairedAgents(List<PairedAgent> agents) async {
    final list = agents
        .map(
          (a) => {
            'relayUrl': a.relayUrl,
            'agentDeviceId': a.agentDeviceId,
            'agentName': a.agentName,
            // Session keys are per-connection and never persisted (v2).
          },
        )
        .toList();
    await _storage.write(
      key: scopedStorageKey('paired_agents'),
      value: jsonEncode(list),
    );
  }

  Future<void> clearPairedAgents() async {
    await _storage.delete(key: scopedStorageKey('paired_agents'));
  }
}
