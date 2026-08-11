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
  group('sessionRowStatus', () {
    AgentWorkStatus call({
      AgentWorkStatus? advert,
      Map<String, AgentWorkStatus>? perSession,
      String sessionId = 's1',
      bool running = true,
      AgentWorkStatus? live,
    }) => sessionRowStatus(
      advert: advert,
      perSession: perSession,
      sessionId: sessionId,
      running: running,
      live: live,
    );

    test('the open project\'s live stamp outranks a lagging advert', () {
      // The chat you are looking at moves on its own data plane; the Recent row
      // must not keep saying "done" until the machine's advert comes round.
      expect(
        call(
          live: AgentWorkStatus.working,
          perSession: const {'s1': AgentWorkStatus.done},
          running: false,
        ),
        AgentWorkStatus.working,
      );
    });

    test('a running session with no advert at all is done, not working', () {
      // The regression this guards: a merely-open session used to read
      // "Working" forever. Only the bridge's advert (a prompt in flight) can
      // say working now.
      expect(call(), AgentWorkStatus.done);
    });

    test('a stopped session is done even while the project is busy', () {
      expect(
        call(advert: AgentWorkStatus.working, running: false),
        AgentWorkStatus.done,
      );
    });

    test('a per-session entry outranks a stale cached running:false', () {
      // The bridge files a status only for sessions it lists as RUNNING, so the
      // entry proves liveness. `running` comes from the cached row, which loads
      // false from disk — masking on it blanked every Recent row after a
      // restart, including the session the agent was blocked on.
      expect(
        call(
          perSession: const {'s1': AgentWorkStatus.attention},
          running: false,
        ),
        AgentWorkStatus.attention,
      );
    });

    test('the session\'s own status wins over the project rollup', () {
      // The point of the per-session view: a sibling being blocked must not
      // paint this row amber.
      expect(
        call(
          advert: AgentWorkStatus.attention,
          perSession: const {
            's1': AgentWorkStatus.working,
            's2': AgentWorkStatus.attention,
          },
        ),
        AgentWorkStatus.working,
      );
    });

    test('a per-session map present but silent about this row reads done', () {
      // Present-but-missing means the bridge knows this project's sessions and
      // this one isn't among the running ones — NOT "fall back to the project".
      expect(
        call(advert: AgentWorkStatus.working, perSession: const {}),
        AgentWorkStatus.done,
      );
    });

    test('no per-session map falls back to the project advert', () {
      // Older bridge / cold project: the rollup is all we have.
      for (final s in AgentWorkStatus.values) {
        expect(call(advert: s), s);
      }
    });
  });

  group('sessionWorkStatusProvider', () {
    test('reads the per-session map, falling back to the project', () {
      final container = _seeded('m1', const {
        'm1.p': AgentWorkStatus.attention,
      });
      // No per-session data yet → the rollup.
      expect(
        container.read(
          sessionWorkStatusProvider((
            entryId: 'm1.p',
            sessionId: 's1',
            running: true,
          )),
        ),
        AgentWorkStatus.attention,
      );
      container
          .read(remoteSessionStatusProvider.notifier)
          .setMachineSessionStatuses('m1', const {
            'm1.p': {
              's1': AgentWorkStatus.working,
              's2': AgentWorkStatus.attention,
            },
          });
      expect(
        container.read(
          sessionWorkStatusProvider((
            entryId: 'm1.p',
            sessionId: 's1',
            running: true,
          )),
        ),
        AgentWorkStatus.working,
      );
      expect(
        container.read(
          sessionWorkStatusProvider((
            entryId: 'm1.p',
            sessionId: 's2',
            running: true,
          )),
        ),
        AgentWorkStatus.attention,
      );
    });

    test('a closed socket clears the machine\'s per-session entries', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(remoteSessionStatusProvider.notifier);
      notifier.setMachineSessionStatuses('m1', const {
        'm1.p': {'s1': AgentWorkStatus.working},
      });
      notifier.setMachineSessionStatuses('m1', const {});
      expect(container.read(remoteSessionStatusProvider), isEmpty);
    });

    test('an unchanged re-delivery keeps the SAME inner map instance', () {
      // Widgets select the inner map; a fresh-but-equal instance would rebuild
      // every session row on every advert re-push.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(remoteSessionStatusProvider.notifier);
      notifier.setMachineSessionStatuses('m1', {
        'm1.p': {'s1': AgentWorkStatus.working},
      });
      final first = container.read(remoteSessionStatusProvider)['m1.p'];
      notifier.setMachineSessionStatuses('m1', {
        'm1.p': {'s1': AgentWorkStatus.working},
      });
      expect(
        identical(container.read(remoteSessionStatusProvider)['m1.p'], first),
        isTrue,
      );
    });

    test('local (bare-key) writes do not disturb a machine\'s entries', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(remoteSessionStatusProvider.notifier);
      notifier.setMachineSessionStatuses('m1', const {
        'm1.p': {'s1': AgentWorkStatus.working},
      });
      notifier.setLocalSessionStatuses(const {
        'antgrid': {'s9': AgentWorkStatus.attention},
      });
      final state = container.read(remoteSessionStatusProvider);
      expect(state['m1.p'], const {'s1': AgentWorkStatus.working});
      expect(state['antgrid'], const {'s9': AgentWorkStatus.attention});
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
      container.read(remoteProjectStatusProvider.notifier).setMachineStatuses(
        'm2',
        const {'m2.a': AgentWorkStatus.attention},
      );
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
      container.read(remoteProjectStatusProvider.notifier).setLocalStatuses(
        const {'antgrid': AgentWorkStatus.attention},
      );
      expect(container.read(machineWorkStatusProvider('m1')), isNull);
    });
  });
}
