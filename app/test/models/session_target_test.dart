import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_target.dart';

void main() {
  group('SessionTarget.registrationId', () {
    test('LocalProject registrationId is the projectId', () {
      expect(const LocalProject('proj-abc').registrationId, 'proj-abc');
      expect(const LocalProject('proj-abc').isLocal, isTrue);
    });

    test('RemoteProject registrationId is deviceUuid.projectId', () {
      const t = RemoteProject(machineUuid: 'uuid-1', projectId: 'p1');
      expect(t.registrationId, 'uuid-1.p1');
      expect(t.machineUuid, 'uuid-1');
      expect(t.isLocal, isFalse);
    });

    test('RemoteTarget.legacy preserves the raw agentDeviceId verbatim', () {
      expect(RemoteTarget.legacy('uuid-1.p1').registrationId, 'uuid-1.p1');
      expect(RemoteTarget.legacy('uuid-1').registrationId, 'uuid-1');
      expect(RemoteTarget.legacy('uuid-1').isLocal, isFalse);
    });

    test('value equality by registrationId + locality', () {
      expect(const LocalProject('p'), const LocalProject('p'));
      expect(
        const RemoteProject(machineUuid: 'u', projectId: 'p'),
        const RemoteProject(machineUuid: 'u', projectId: 'p'),
      );
      expect(
        const RemoteProject(machineUuid: 'u1', projectId: 'p') ==
            const RemoteProject(machineUuid: 'u2', projectId: 'p'),
        isFalse,
      );
      expect(
        const RemoteProject(machineUuid: 'u', projectId: 'p1') ==
            const RemoteProject(machineUuid: 'u', projectId: 'p2'),
        isFalse,
      );
      expect(RemoteTarget.legacy('x'), RemoteTarget.legacy('x'));
      expect(const LocalProject('p') == RemoteTarget.legacy('p'), isFalse);
    });

    test('hashCode is equal for equal targets', () {
      expect(
        const LocalProject('p').hashCode,
        const LocalProject('p').hashCode,
      );
      expect(
        const RemoteProject(machineUuid: 'u', projectId: 'p').hashCode,
        const RemoteProject(machineUuid: 'u', projectId: 'p').hashCode,
      );
      expect(
        RemoteTarget.legacy('x').hashCode,
        RemoteTarget.legacy('x').hashCode,
      );
    });
  });
}
