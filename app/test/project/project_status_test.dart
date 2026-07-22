import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_hello.dart';
import 'package:antgrid/models/service_status.dart';
import 'package:antgrid/project/project_status.dart';

void main() {
  group('ProjectStatus', () {
    test('empty constructor yields zeroed defaults', () {
      const status = ProjectStatus.empty();
      expect(status.configError, false);
      expect(status.configErrorMessage, isNull);
      expect(status.activeCommandName, isNull);
      expect(status.detectedPorts, isEmpty);
      expect(status.services, isEmpty);
      expect(status.agentHello, isNull);
      expect(status.lastUpdatedAt, isNull);
    });

    test(
      'copyWith updates fields and clear flags win over explicit values',
      () {
        const initial = ProjectStatus(
          configError: true,
          configErrorMessage: 'boom',
          activeCommandName: 'build',
          detectedPorts: [3000, 4000],
          services: [],
          agentHello: AgentHello(version: '1.0.0'),
        );

        // Plain copyWith
        final updated = initial.copyWith(
          configError: false,
          detectedPorts: const [8080],
        );
        expect(updated.configError, false);
        expect(updated.configErrorMessage, 'boom');
        expect(updated.detectedPorts, [8080]);

        // Clear flags
        final cleared = initial.copyWith(
          clearConfigErrorMessage: true,
          clearActiveCommandName: true,
          clearAgentHello: true,
        );
        expect(cleared.configErrorMessage, isNull);
        expect(cleared.activeCommandName, isNull);
        expect(cleared.agentHello, isNull);

        // clearX:true wins even when an explicit value is also passed
        final clearWins = initial.copyWith(
          configErrorMessage: 'override',
          clearConfigErrorMessage: true,
        );
        expect(clearWins.configErrorMessage, isNull);
      },
    );

    test('JSON round-trip preserves all fields and omits null optionals', () {
      final timestamp = DateTime.utc(2026, 5, 15, 12, 0, 0);
      final original = ProjectStatus(
        configError: true,
        configErrorMessage: 'something failed',
        activeCommandName: 'test',
        detectedPorts: const [3000, 8080],
        services: const [
          ServiceStatus(
            id: 's1',
            name: 'dev',
            running: true,
            command: 'bun dev',
          ),
        ],
        agentHello: const AgentHello(version: '1.0.0', tool: 'claude'),
        lastUpdatedAt: timestamp,
      );

      final json = original.toJson();
      final restored = ProjectStatus.fromJson(json);
      expect(restored, equals(original));

      // Null fields are omitted on empty
      const empty = ProjectStatus.empty();
      final emptyJson = empty.toJson();
      expect(emptyJson.containsKey('configErrorMessage'), false);
      expect(emptyJson.containsKey('activeCommandName'), false);
      expect(emptyJson.containsKey('agentHello'), false);
      expect(emptyJson.containsKey('lastUpdatedAt'), false);
    });

    test('value equality and hashCode are structural', () {
      final t = DateTime.utc(2026, 5, 15);
      final a = ProjectStatus(
        configError: false,
        detectedPorts: const [3000],
        services: const [
          ServiceStatus(id: 's1', name: 'dev', running: true, command: 'x'),
        ],
        agentHello: const AgentHello(version: '1.0.0'),
        lastUpdatedAt: t,
      );
      final b = ProjectStatus(
        configError: false,
        detectedPorts: const [3000],
        services: const [
          ServiceStatus(id: 's1', name: 'dev', running: true, command: 'x'),
        ],
        agentHello: const AgentHello(version: '1.0.0'),
        lastUpdatedAt: t,
      );
      final c = a.copyWith(configError: true);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
