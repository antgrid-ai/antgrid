import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/agent_coordinates.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/recent_agents_store.dart';

InventoryAgent _inv({
  String uuid = 'M',
  String label = 'Fresh Agent',
  String pub = 'FRESH_PUB',
  String? relayUrl = 'wss://fresh.relay',
  String? machineName = 'fresh-host',
}) => InventoryAgent(
  deviceUuid: uuid,
  displayName: label,
  platform: 'linux',
  ed25519Pub: pub,
  relayUrl: relayUrl,
  machineName: machineName,
);

RecentAgent _cached({
  String uuid = 'M',
  String label = 'Stale Agent',
  String pub = 'STALE_PUB',
  String relayUrl = 'wss://stale.relay',
  String? machineName = 'stale-host',
}) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: uuid,
    agentLabel: label,
    agentEd25519Pubkey: pub,
    relayUrl: relayUrl,
    pairedAt: now,
    lastConnectedAt: now,
    hostMachineName: machineName,
  );
}

void main() {
  group('resolveAgentCoordinates — freshness polarity', () {
    test('fresh inventory OVERRIDES a stale cached relayUrl + pubkey', () {
      // The core bug: the reconnect path used to dial/verify the values pinned
      // on the cached record. Inventory must win.
      final coords = resolveAgentCoordinates(
        base: 'M',
        inventory: [_inv()],
        cached: _cached(),
      );

      expect(coords, isNotNull);
      expect(coords!.relayUrl, 'wss://fresh.relay'); // NOT wss://stale.relay
      expect(coords.ed25519Pub, 'FRESH_PUB'); // NOT STALE_PUB
      expect(coords.label, 'Fresh Agent');
      expect(coords.machineName, 'fresh-host');
    });

    test('a transiently-null inventory relayUrl falls back per-field to cache, '
        'but the fresh pubkey still wins', () {
      final coords = resolveAgentCoordinates(
        base: 'M',
        inventory: [_inv(relayUrl: null, machineName: null)],
        cached: _cached(),
      );

      // relayUrl/machineName: don't blank a known-good address on a heartbeat lag.
      expect(coords!.relayUrl, 'wss://stale.relay');
      expect(coords.machineName, 'stale-host');
      // pubkey/label: authoritative from inventory even so.
      expect(coords.ed25519Pub, 'FRESH_PUB');
      expect(coords.label, 'Fresh Agent');
    });

    test('no inventory (offline) → the cache is the explicit fallback', () {
      final coords = resolveAgentCoordinates(
        base: 'M',
        inventory: null,
        cached: _cached(),
      );

      expect(coords!.relayUrl, 'wss://stale.relay');
      expect(coords.ed25519Pub, 'STALE_PUB');
      expect(coords.label, 'Stale Agent');
    });

    test('inventory present but no matching machine → cache fallback', () {
      final coords = resolveAgentCoordinates(
        base: 'M',
        inventory: [_inv(uuid: 'OTHER')],
        cached: _cached(),
      );

      expect(coords!.relayUrl, 'wss://stale.relay');
      expect(coords.ed25519Pub, 'STALE_PUB');
    });

    test('neither inventory nor cache knows the machine → null', () {
      final coords = resolveAgentCoordinates(
        base: 'M',
        inventory: [_inv(uuid: 'OTHER')],
        cached: null,
      );
      expect(coords, isNull);
    });
  });
}
