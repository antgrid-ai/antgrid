import 'package:antgrid/providers/auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote access is ungated for every tier during beta', () {
    // Flipping kRemoteAccessFreeDuringBeta must fail here loudly: whoever
    // restores the gate rewrites these expectations for gated behavior.
    expect(kRemoteAccessFreeDuringBeta, isTrue);
    expect(requiresProForRemote(null), isFalse);
    expect(requiresProForRemote('free'), isFalse);
    expect(requiresProForRemote('trial'), isFalse);
    expect(requiresProForRemote('pro'), isFalse);
  });
}
