import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/session_bus/directory_warm_targets.dart';

InventoryAgent _agent(String uuid, {DateTime? lastSeenAt}) => InventoryAgent(
  deviceUuid: uuid,
  displayName: uuid,
  platform: 'windows',
  ed25519Pub: 'k',
  lastSeenAt: lastSeenAt,
);

void main() {
  group('directoryWarmCandidates', () {
    test('skips this machine and every peer already open', () {
      final missed = directoryWarmCandidates(
        [_agent('local'), _agent('open'), _agent('cold')],
        'local',
        const ['open'],
      );

      expect(missed, {'cold'});
    });

    test('takes the most recently seen first, never seen last', () {
      final missed = directoryWarmCandidates(
        [
          _agent('never'),
          _agent('old', lastSeenAt: DateTime(2024, 1, 1)),
          _agent('recent', lastSeenAt: DateTime(2024, 6, 1)),
        ],
        'local',
        const [],
        cap: 2,
      );

      // Nothing here can tell which machine holds the repo the read asked
      // about — that is what connecting would answer — so recency is the whole
      // ranking, and a machine the account has never seen connect is the
      // weakest candidate rather than an arbitrary one.
      expect(missed, {'recent', 'old'});
    });

    test('one missed read cannot warm a whole account', () {
      final missed = directoryWarmCandidates(
        [for (var i = 0; i < 20; i++) _agent('m$i')],
        'local',
        const [],
      );

      expect(missed, hasLength(kDirectoryWarmCap));
    });
  });

  group('DirectoryWarmTargets', () {
    late ProviderContainer container;
    DirectoryWarmTargets notifier() =>
        container.read(directoryWarmTargetsProvider.notifier);

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('holds nothing until a read misses', () {
      expect(container.read(directoryWarmTargetsProvider), isEmpty);
    });

    test('a warmed machine falls out on its own, with nothing to unpin it', () {
      final t0 = DateTime(2024, 1, 1);
      notifier().warm({'m1'}, t0);
      expect(container.read(directoryWarmTargetsProvider), {'m1'});

      notifier().prune(t0.add(kDirectoryWarmWindow - const Duration(seconds: 1)));
      expect(container.read(directoryWarmTargetsProvider), {'m1'});

      notifier().prune(t0.add(kDirectoryWarmWindow));
      expect(container.read(directoryWarmTargetsProvider), isEmpty);
    });

    test('a machine asked about again keeps its socket', () {
      final t0 = DateTime(2024, 1, 1);
      notifier().warm({'m1'}, t0);
      notifier().warm({'m1'}, t0.add(const Duration(minutes: 4)));

      notifier().prune(t0.add(kDirectoryWarmWindow));
      expect(container.read(directoryWarmTargetsProvider), {'m1'});
    });

    // This set is unioned into `controlPlaneAliveTargetsProvider`, whose fan-in
    // has crashed a frame before. A fresh Set is never `==` to the last one, so
    // an unguarded emit would ripple a no-op rebuild into the reaper on every
    // single pump tick.
    test('an unchanged membership does not notify', () {
      final t0 = DateTime(2024, 1, 1);
      var notifications = 0;
      container.listen(directoryWarmTargetsProvider, (_, _) => notifications++);

      notifier().warm({'m1'}, t0);
      expect(notifications, 1);

      notifier().prune(t0);
      notifier().warm({'m1'}, t0.add(const Duration(seconds: 1)));
      expect(notifications, 1);
    });
  });
}
