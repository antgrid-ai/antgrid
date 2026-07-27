import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/storage/recent_agents_store.dart';

void main() {
  test('RecentAgent round-trips hostMachineName; tolerates missing field', () {
    final a = RecentAgent(
      agentDeviceId: 'd',
      agentLabel: 'l',
      agentEd25519Pubkey: 'k',
      relayUrl: 'wss://r',
      pairedAt: DateTime(2026),
      lastConnectedAt: DateTime(2026),
      hostMachineName: 'Mac Studio',
    );
    final back = RecentAgent.fromJson(a.toJson());
    expect(back.hostMachineName, 'Mac Studio');

    final legacy = Map<String, dynamic>.from(a.toJson())
      ..remove('hostMachineName');
    expect(RecentAgent.fromJson(legacy).hostMachineName, isNull);
  });
}
