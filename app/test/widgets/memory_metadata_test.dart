import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/widgets/memory/memory_detail_pane.dart';
import 'package:antgrid/widgets/memory/memory_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_export_fixtures.dart';
import '../helpers/prefs_test_mock.dart';

const _target = MemoryTarget.machine();
final _record = {
  ...memoryExportRecord('current'),
  'title': 'Recover a Windows build',
  'description': 'Use after a failed CMake configure.',
  'content': 'Fix the missing JDK, then recreate the Windows build directory.',
};

void main() {
  setUp(useInMemoryPrefs);

  Future<List<Map<String, dynamic>>> mount(
    WidgetTester tester, {
    List<Map<String, dynamic>> earlier = const [],
    bool compact = false,
  }) async {
    final saves = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryRequestProvider(_target).overrideWithValue((request) async {
            switch (request['op']) {
              case 'status':
                return {
                  'available': true,
                  'enabled': true,
                  'search_status': 'ready',
                };
              case 'get':
                return {'record': _record, 'earlier': earlier};
              case 'save':
                saves.add(request);
                return {'id': 'corrected'};
              default:
                return {'projects': [], 'memories': 1};
            }
          }),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: compact
                ? MemoryDetailPane(
                    target: _target,
                    id: 'current',
                    compact: true,
                    onSaved: (_) {},
                    onForgotten: () {},
                  )
                : SingleChildScrollView(
                    child: MemoryDetailPane(
                      target: _target,
                      id: 'current',
                      onSaved: (_) {},
                      onForgotten: () {},
                    ),
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saves;
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final button = find.widgetWithText(AbButton, label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('list rows show metadata and older records retain their body', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: Column(
            children: [
              for (final json in [_record, memoryExportRecord('legacy')])
                MemoryListRow(
                  record: MemoryRecord.fromJson(json),
                  projectLabel: 'Project',
                  projectRemoved: false,
                  agentLabel: 'Codex',
                  selected: false,
                  compact: true,
                  onTap: () {},
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.text(_record['title'] as String), findsOneWidget);
    expect(find.text(_record['description'] as String), findsOneWidget);
    expect(find.text(_record['content'] as String), findsNothing);
    expect(
      find.text(memoryExportRecord('legacy')['content'] as String),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail and earlier versions show metadata beside full bodies', (
    tester,
  ) async {
    await mount(
      tester,
      earlier: [
        {
          ...memoryExportRecord('old', lifecycle: 'superseded'),
          'title': 'Old title',
          'description': 'Old description',
        },
        memoryExportRecord('legacy', lifecycle: 'superseded'),
      ],
    );
    expect(find.text(_record['title'] as String), findsOneWidget);
    expect(find.text(_record['description'] as String), findsOneWidget);
    expect(find.text(_record['content'] as String), findsOneWidget);
    await tester.ensureVisible(find.text('2 earlier versions'));
    await tester.tap(find.text('2 earlier versions'));
    await tester.pumpAndSettle();
    expect(find.text('Old title'), findsOneWidget);
    expect(find.text('Old description'), findsOneWidget);
    expect(
      find.text(memoryExportRecord('old')['content'] as String),
      findsOneWidget,
    );
    expect(
      find.text(memoryExportRecord('legacy')['content'] as String),
      findsOneWidget,
    );
  });

  testWidgets('a metadata-only correction submits both editable fields', (
    tester,
  ) async {
    final saves = await mount(tester);
    await tap(tester, 'Edit');
    await tester.enterText(
      find.byKey(const Key('memory-edit-title')),
      'Revised title',
    );
    await tester.pump();
    await tap(tester, 'Save changes');
    final save = saves.single['save'] as Map;
    expect(save['title'], 'Revised title');
    expect(save['description'], _record['description']);
    expect(save['content'], _record['content']);
    expect(save['supersedes'], 'current');
  });

  testWidgets('clearing optional fields omits them from the correction', (
    tester,
  ) async {
    final saves = await mount(tester);
    await tap(tester, 'Edit');
    await tester.enterText(find.byKey(const Key('memory-edit-title')), '');
    await tester.enterText(
      find.byKey(const Key('memory-edit-description')),
      '',
    );
    await tap(tester, 'Save changes');
    final save = saves.single['save'] as Map;
    expect(save.containsKey('title'), isFalse);
    expect(save.containsKey('description'), isFalse);
    expect(save['content'], _record['content']);
  });

  testWidgets(
    'compact editor blocks an oversized UTF-8 title and preserves the draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saves = await mount(tester, compact: true);
      await tap(tester, 'Edit');
      final draft = '界' * 86;
      await tester.enterText(find.byKey(const Key('memory-edit-title')), draft);
      await tester.pumpAndSettle();
      expect(find.text('Title exceeds 256 UTF-8 bytes.'), findsOneWidget);
      expect(
        tester
            .widget<AbButton>(find.widgetWithText(AbButton, 'Save changes'))
            .onTap,
        isNull,
      );
      expect(saves, isEmpty);
      expect(find.text(draft), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('memory-edit-title')),
        'Valid title',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AbButton>(find.widgetWithText(AbButton, 'Save changes'))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
