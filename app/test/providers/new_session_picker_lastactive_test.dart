import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/new_session_picker.dart';

void main() {
  test('local project carries lastOpenedAt as lastActiveAt', () {
    final opened = DateTime(2026, 6, 1, 9, 30);
    final sources = buildPickerSources(
      localProjects: [
        AbProject(
          projectId: 'p1',
          folder: '/repo/p1',
          displayName: 'P1',
          hostDeviceUuid: 'host-1',
          hostMachineName: '',
          lastOpenedAt: opened,
        ),
      ],
      recents: const [],
      inventory: const [],
    );

    final local = sources.firstWhere((s) => s.id == 'local');
    expect(local.projects.single.lastActiveAt, opened);
  });

  test(
    'empty inputs without local yield a single Remote placeholder source',
    () {
      final sources = buildPickerSources(
        localProjects: const [],
        recents: const [],
        inventory: const [],
        includeLocal: false, // mobile: no local source, no machines paired yet
      );

      expect(sources, hasLength(1));
      expect(sources.single.id, 'machine:none');
      expect(sources.single.label, 'Remote');
      expect(sources.single.isLocal, isFalse);
      expect(sources.single.machineUuid, isNull);
      expect(sources.single.projects, isEmpty);
    },
  );
}
