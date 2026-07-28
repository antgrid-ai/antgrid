// The app's relay slot id. Mirrored by `bridge/src/relay-slot.ts` — a
// divergence here is an admission failure on the bridge, so these cases pin the
// exact string shape both sides agree on.
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  test('a slot scopes the account device by the machine it dials', () {
    expect(relaySlotId('device-1', 'machine-a'), 'device-1#machine-a');
  });

  test('every machine gets a distinct slot for one account device', () {
    // The whole point: the relay arbitrates per `hello.deviceId` and supersedes
    // an equal epoch, so two machines wanted at once must not share a slot.
    expect(
      relaySlotId('device-1', 'machine-a'),
      isNot(relaySlotId('device-1', 'machine-b')),
    );
  });

  test('a slot resolves back to the account device identity is keyed by', () {
    expect(baseSlotDeviceId(relaySlotId('device-1', 'machine-a')), 'device-1');
  });

  test('an unscoped id passes through unchanged', () {
    // A client that dials without a slot must keep resolving — the bridge runs
    // the same strip over every route id it receives, ours or not.
    expect(baseSlotDeviceId('device-1'), 'device-1');
  });

  test('a machine id containing the separator does not corrupt the base', () {
    // First separator wins on both sides; anything after it is scope.
    expect(baseSlotDeviceId('device-1#machine-a#extra'), 'device-1');
  });
}
