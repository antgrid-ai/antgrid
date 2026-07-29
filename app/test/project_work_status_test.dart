import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/services/control_plane_client.dart';

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
}
