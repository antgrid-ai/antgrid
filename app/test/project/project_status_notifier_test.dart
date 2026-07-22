import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_status.dart';

void main() {
  group('ProjectStatusNotifier', () {
    test(
      'agent:status updates services',
      () async {
        final ctrl = StreamController<Map<String, dynamic>>.broadcast();
        final notifier = ProjectStatusNotifier(ctrl.stream);
        ctrl.add({
          'id': '0',
          'timestamp': 0,
          'type': 'agent:status',
          'projectId': 'p',
          'terminals': [
            {
              'terminalId': 't1',
              'name': 't1',
              'running': true,
              'shell': 'bash',
              'cols': 80,
              'rows': 24,
            },
            {
              'terminalId': 't2',
              'name': 't2',
              'running': false,
              'shell': 'bash',
              'cols': 80,
              'rows': 24,
            },
          ],
          'services': [
            {
              'id': 'svc-1',
              'name': 'dev',
              'running': true,
              'command': 'npm run dev',
            },
          ],
          'commands': [],
          'proxies': [],
          'ports': [],
        });
        await Future<void>.delayed(Duration.zero);
        expect(notifier.value.services, hasLength(1));
        notifier.dispose();
        await ctrl.close();
      },
    );

    test('ports:update populates detectedPorts', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final notifier = ProjectStatusNotifier(ctrl.stream);
      ctrl.add({
        'id': '0',
        'timestamp': 0,
        'type': 'ports:update',
        'projectId': 'p',
        'ports': [
          {'port': 3000, 'pid': 1234, 'processName': 'node', 'label': 'web'},
          {'port': 5173},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.detectedPorts, containsAll([3000, 5173]));
      notifier.dispose();
      await ctrl.close();
    });

    test('agent:hello populates agentHello', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final notifier = ProjectStatusNotifier(ctrl.stream);
      ctrl.add({
        'id': '0',
        'timestamp': 0,
        'type': 'agent:hello',
        'tool': 'claude',
        'version': '1.0.0',
        'flags': <String>[],
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.agentHello, isNotNull);
      expect(notifier.value.agentHello!.version, '1.0.0');
      notifier.dispose();
      await ctrl.close();
    });

    test('config:changed with error sets configError', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final notifier = ProjectStatusNotifier(ctrl.stream);
      ctrl.add({
        'id': '0',
        'timestamp': 0,
        'type': 'config:changed',
        'projectId': 'p',
        'error': 'YAML parse error at line 12',
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.configError, isTrue);
      expect(notifier.value.configErrorMessage, contains('YAML'));
      notifier.dispose();
      await ctrl.close();
    });

    test('a clean config frame clears a prior config error', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final notifier = ProjectStatusNotifier(ctrl.stream);
      ctrl.add({
        'id': '0',
        'timestamp': 0,
        'type': 'config:changed',
        'projectId': 'p',
        'error': 'bad yaml',
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.configError, isTrue);

      ctrl.add({
        'id': '1',
        'timestamp': 1,
        'type': 'config:changed',
        'projectId': 'p',
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.configError, isFalse);
      expect(notifier.value.configErrorMessage, isNull);
      notifier.dispose();
      await ctrl.close();
    });

    test('agent:status does NOT clear a config error', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final notifier = ProjectStatusNotifier(ctrl.stream);
      ctrl.add({
        'id': '0',
        'timestamp': 0,
        'type': 'config:read-result',
        'projectId': 'p',
        'error': 'cannot read antgrid.yaml',
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.configError, isTrue);

      ctrl.add({
        'id': '1',
        'timestamp': 1,
        'type': 'agent:status',
        'projectId': 'p',
        'terminals': [],
        'services': [],
        'commands': [],
        'proxies': [],
        'ports': [],
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.configError, isTrue);
      notifier.dispose();
      await ctrl.close();
    });

    test('a non-config error frame does NOT set configError', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final notifier = ProjectStatusNotifier(ctrl.stream);
      ctrl.add({
        'id': '0',
        'timestamp': 0,
        'type': 'git:checkout-result',
        'projectId': 'p',
        'success': false,
        'error': 'checkout failed',
      });
      await Future<void>.delayed(Duration.zero);
      expect(notifier.value.configError, isFalse);
      notifier.dispose();
      await ctrl.close();
    });
  });
}
