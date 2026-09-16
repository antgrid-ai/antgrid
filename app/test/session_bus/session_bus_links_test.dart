import 'package:antgrid/session_bus/session_bus_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer _container({Duration idle = kSessionBusLinkIdle}) {
  final c = ProviderContainer(
    overrides: [sessionBusLinkIdleProvider.overrideWithValue(idle)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('a peer cannot mint demand without bound, and a live exchange outlives the flood', () async {
    final c = _container();
    final demand = c.read(sessionBusLinksProvider.notifier);

    for (var i = 0; i < kSessionBusMaxLinks; i++) {
      demand.reach('m-$i', 'p-$i');
    }
    // The one exchange that is actually running: a frame arrived, so its
    // deadline moved forward while every other entry's stayed where it was.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    demand.reach('m-0', 'p-0');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // A connected peer chooses what it writes in a frame's address, so this is
    // ONE peer inventing machines, not many peers arriving. Each entry would
    // otherwise become a relay dial and a pin, and a pinned bucket is exempt
    // from the registry's own cap.
    for (var i = 0; i < 8; i++) {
      demand.reach('flood-$i', 'p-flood');
    }

    final links = c.read(sessionBusLinksProvider);
    expect(links.length, kSessionBusMaxLinks);
    expect(links.peerMachineIds, contains('m-0'));
    expect(
      links.peerMachineIds,
      isNot(contains('m-1')),
      reason: 'what goes is the coldest, which is what nothing is exchanging on',
    );
  });

  test('demand under the cap is untouched, and a refresh keeps its position', () {
    final c = _container();
    final demand = c.read(sessionBusLinksProvider.notifier);

    demand.reach('m-a', 'p-a');
    demand.reach('m-b', 'p-b');
    final before = c.read(sessionBusLinksProvider);
    demand.reach('m-a', 'p-a');

    // Order is part of the equality, and `controlPlaneAliveTargetsProvider` is
    // on the other end of it — a refresh that reordered would rebuild that
    // fan-in on every frame of a busy exchange.
    expect(c.read(sessionBusLinksProvider), before);
  });
}
