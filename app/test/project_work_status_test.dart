import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';

/// Container with the advert map seeded for [machineUuid]. The controller's
/// build() degrades to an empty map when the cached-sessions store isn't
/// overridden, so nothing else needs stubbing here.
ProviderContainer _seeded(
  String machineUuid,
  Map<String, AgentWorkStatus> statuses,
) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container
      .read(remoteProjectStatusProvider.notifier)
      .setMachineStatuses(machineUuid, statuses);
  return container;
}

void main() {
  group('recentRowStatus', () {
    test('a running session with no advert is done, not working', () {
      // The regression this guards: a merely-open session used to read
      // "Working" forever. Only the bridge's advert (a prompt in flight) can
      // say working now.
      expect(recentRowStatus(null, true), AgentWorkStatus.done);
    });

    test('a stopped session is done even while the project is busy', () {
      expect(
        recentRowStatus(AgentWorkStatus.working, false),
        AgentWorkStatus.done,
      );
      expect(
        recentRowStatus(AgentWorkStatus.attention, false),
        AgentWorkStatus.done,
      );
    });

    test('a running session takes the project advert', () {
      for (final s in AgentWorkStatus.values) {
        expect(recentRowStatus(s, true), s);
      }
    });
  });

  group('machineWorkStatusProvider', () {
    test('no advert for the machine reads null, not done', () {
      // Null is what lets the collapsed machine header hide the dot entirely
      // (offline / older bridge) instead of claiming a confident "done".
      final container = _seeded('m1', const {});
      expect(container.read(machineWorkStatusProvider('m1')), isNull);
    });

    test('attention beats error, working and done', () {
      final container = _seeded('m1', const {
        'm1.a': AgentWorkStatus.done,
        'm1.b': AgentWorkStatus.error,
        'm1.c': AgentWorkStatus.working,
        'm1.d': AgentWorkStatus.attention,
      });
      expect(
        container.read(machineWorkStatusProvider('m1')),
        AgentWorkStatus.attention,
      );
    });

    test('error beats working and done', () {
      final container = _seeded('m1', const {
        'm1.a': AgentWorkStatus.working,
        'm1.b': AgentWorkStatus.error,
        'm1.c': AgentWorkStatus.done,
      });
      expect(
        container.read(machineWorkStatusProvider('m1')),
        AgentWorkStatus.error,
      );
    });

    test('working beats done regardless of arrival order', () {
      // Guards the `best == null || best == done` upgrade rule: a done project
      // seen FIRST must not pin the aggregate at done.
      for (final order in const [
        {'m1.a': AgentWorkStatus.done, 'm1.b': AgentWorkStatus.working},
        {'m1.a': AgentWorkStatus.working, 'm1.b': AgentWorkStatus.done},
      ]) {
        final container = _seeded('m1', order);
        expect(
          container.read(machineWorkStatusProvider('m1')),
          AgentWorkStatus.working,
        );
      }
    });

    test('all-done projects read done', () {
      final container = _seeded('m1', const {
        'm1.a': AgentWorkStatus.done,
        'm1.b': AgentWorkStatus.done,
      });
      expect(
        container.read(machineWorkStatusProvider('m1')),
        AgentWorkStatus.done,
      );
    });

    test('another machine\'s attention does not leak into this one', () {
      final container = _seeded('m1', const {'m1.a': AgentWorkStatus.done});
      container
          .read(remoteProjectStatusProvider.notifier)
          .setMachineStatuses('m2', const {'m2.a': AgentWorkStatus.attention});
      expect(
        container.read(machineWorkStatusProvider('m1')),
        AgentWorkStatus.done,
      );
      expect(
        container.read(machineWorkStatusProvider('m2')),
        AgentWorkStatus.attention,
      );
    });

    test('a bare local projectId key belongs to no machine', () {
      // setLocalStatuses writes unprefixed keys for the desktop host poll —
      // the '<uuid>.' prefix match must not treat those as any machine's.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(remoteProjectStatusProvider.notifier)
          .setLocalStatuses(const {'antgrid': AgentWorkStatus.attention});
      expect(container.read(machineWorkStatusProvider('m1')), isNull);
    });
  });
}
