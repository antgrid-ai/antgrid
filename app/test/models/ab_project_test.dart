import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_project.dart';

void main() {
  group('AbProject', () {
    final now = DateTime.utc(2026, 5, 28, 12, 0, 0);

    test('toJson / fromJson roundtrip with new fields', () {
      final project = AbProject(
        projectId: 'proj-1',
        folder: '/home/user/my-project',
        displayName: 'My Project',
        hostDeviceUuid: 'device-abc-123',
        hostMachineName: 'MacBook Pro',
        lastOpenedAt: now,
      );

      final json = project.toJson();
      final restored = AbProject.fromJson(json);

      expect(restored.projectId, 'proj-1');
      expect(restored.folder, '/home/user/my-project');
      expect(restored.displayName, 'My Project');
      expect(restored.hostDeviceUuid, 'device-abc-123');
      expect(restored.hostMachineName, 'MacBook Pro');
      expect(restored.lastOpenedAt, now);
    });

    test('toJson / fromJson roundtrip preserves hostMachineName empty string',
        () {
      final project = AbProject(
        projectId: 'proj-2',
        folder: '/home/user/other',
        displayName: 'Other',
        hostDeviceUuid: 'device-xyz',
        hostMachineName: '',
        lastOpenedAt: now,
      );

      final restored = AbProject.fromJson(project.toJson());
      expect(restored.hostMachineName, '');
    });

    test('stray mobileAccessEnabled key in JSON deserializes without error',
        () {
      // Forward-compat: JSON written by an older build that still emits
      // mobileAccessEnabled must load silently (the field is simply ignored).
      final json = <String, dynamic>{
        'projectId': 'proj-stray',
        'folder': '/stray/folder',
        'displayName': 'Stray',
        'hostDeviceUuid': 'device-stray',
        'hostMachineName': 'my-machine',
        'mobileAccessEnabled': true, // stray legacy key
        'lastOpenedAt': now.toIso8601String(),
      };

      final project = AbProject.fromJson(json);

      expect(project.projectId, 'proj-stray');
      expect(project.hostDeviceUuid, 'device-stray');
    });

    group('legacy migration', () {
      test('pre-v2 JSON without hostDeviceUuid migrates to hostDeviceUuid: null',
          () {
        final legacy = <String, dynamic>{
          'projectId': 'proj-old',
          'folder': '/old/folder',
          'displayName': 'Old Project',
          'mode': 'mobileEnabled',
          'agentDeviceId': 'device-foo',
          'lastOpenedAt': now.toIso8601String(),
        };

        final project = AbProject.fromJson(legacy);

        expect(project.projectId, 'proj-old');
        // Pre-v2 agentDeviceId was the agent's identity (per-project or
        // per-host), NOT this device's UUID — we leave hostDeviceUuid null
        // and let isLocalFor treat the project as local-here.
        expect(project.hostDeviceUuid, isNull);
      });

      test('legacy projects round-trip through toJson without inventing a UUID',
          () {
        final legacy = <String, dynamic>{
          'projectId': 'proj-fallback',
          'folder': '/fb/folder',
          'displayName': 'Fallback',
          'mode': 'mobileEnabled',
          'lastOpenedAt': now.toIso8601String(),
        };

        final project = AbProject.fromJson(legacy);
        // The toJson encoding omits hostDeviceUuid entirely when null, so the
        // legacy shape is preserved until the project is explicitly upserted.
        expect(project.toJson().containsKey('hostDeviceUuid'), isFalse);
      });
    });

    group('isLocalFor', () {
      test('returns true when hostDeviceUuid matches', () {
        final project = AbProject(
          projectId: 'p',
          folder: '/f',
          displayName: 'P',
          hostDeviceUuid: 'my-device',
          hostMachineName: 'laptop',
          lastOpenedAt: now,
        );

        expect(project.isLocalFor('my-device'), isTrue);
      });

      test('returns false when hostDeviceUuid does not match', () {
        final project = AbProject(
          projectId: 'p',
          folder: '/f',
          displayName: 'P',
          hostDeviceUuid: 'device-a',
          hostMachineName: 'laptop',
          lastOpenedAt: now,
        );

        expect(project.isLocalFor('device-b'), isFalse);
      });

      test('returns true when hostDeviceUuid is null (pre-v2 migration)', () {
        final project = AbProject(
          projectId: 'p',
          folder: '/f',
          displayName: 'P',
          hostDeviceUuid: null,
          hostMachineName: '',
          lastOpenedAt: now,
        );

        // Pre-v2 had no remote-host concept; every persisted project was
        // local-to-this-device, so a null hostDeviceUuid is treated as local.
        expect(project.isLocalFor('any-device'), isTrue);
      });
    });
  });
}
