// The sample's Memory is what a reviewer with no machine can try, so it must
// answer every op the screen sends in shapes the real parsers accept, and be
// reachable from each Memory entry point inside the sample.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/demo_memory.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/scheduler_timezone.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/screens/demo_home.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

final List<Override> _zone = [
  schedulerLocalTimezoneProvider.overrideWith((_) async => null),
];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<List<MemoryRecord>> _list(
  DemoMemoryBackend backend, {
  MemoryFilter filter = const MemoryFilter(),
}) async {
  final answer = await backend.request(filter.request(0));
  return [
    for (final r in answer['results'] as List)
      MemoryRecord.fromJson((r as Map).cast<String, dynamic>()),
  ];
}

void main() {
  group('DemoMemoryBackend', () {
    test('shows current memories, with one replaced version kept as earlier', () async {
      final backend = DemoMemoryBackend();
      final current = await _list(backend);
      final earlier = await _list(
        backend,
        filter: const MemoryFilter(versions: MemoryVersions.earlier),
      );
      expect(current.map((r) => r.memoryType).toSet(), {
        'preference',
        'note',
        'observation',
        'task_state',
      });
      expect(current.every((r) => r.isCurrent), isTrue);
      expect(earlier.single.lifecycle, 'superseded');

      final projects = MemoryProjects.fromJson(
        await backend.request({'op': 'projects'}),
      );
      expect(projects.memories, current.length);
      expect(projects.labelFor(kDemoProjectId), kDemoDisplayName);

      final status = MemoryStatus.fromJson(
        await backend.request({'op': 'status'}),
      );
      expect(status.enabled, isTrue);
      expect(status.needsAttention, isFalse);
    });

    test('an edit replaces the memory and keeps the old text as history', () async {
      final backend = DemoMemoryBackend();
      final target = (await _list(backend)).first;
      final save = {
        'op': 'save',
        'operation_key': 'k1',
        'save': target.correction(
          content: 'Edited',
          applicability: '',
          evidence: const [],
        ),
      };
      final saved = await backend.request(save);
      // A retried save with the same key must not write twice.
      expect((await backend.request(save))['id'], saved['id']);

      final detail = MemoryDetail.fromJson(
        await backend.request({'op': 'get', 'id': saved['id'], 'earlier': true}),
      );
      expect(detail.record.content, 'Edited');
      expect(detail.record.byApp, isTrue);
      expect(detail.earlier.first.id, target.id);
      expect((await _list(backend)).map((r) => r.id), isNot(contains(target.id)));
    });

    test('forgetting a corrected memory takes its earlier versions too', () async {
      final backend = DemoMemoryBackend();
      final corrected = (await _list(
        backend,
      )).firstWhere((r) => r.supersedes != null);
      await backend.request({'op': 'forget', 'id': corrected.id});
      expect(
        await _list(
          backend,
          filter: const MemoryFilter(versions: MemoryVersions.earlier),
        ),
        isEmpty,
      );
      expect(
        () => backend.request({'op': 'get', 'id': corrected.supersedes}),
        throwsA(
          isA<MemoryException>().having((e) => e.code, 'code', 'NOT_FOUND'),
        ),
      );
    });

    test('search needs every term, and a quoted phrase is one term', () async {
      final backend = DemoMemoryBackend();
      Future<int> hits(String query) async =>
          (await _list(backend, filter: MemoryFilter(query: query))).length;
      expect(await hits('coupon'), 1);
      expect(await hits('coupon cents'), 0);
      expect(await hits('"integer cents"'), 1);
    });

    test('export passes the real export page check', () async {
      final backend = DemoMemoryBackend();
      final page = MemoryExportPage.fromJson(
        await backend.request({'op': 'export'}),
      );
      expect(page.records, isNotEmpty);
      expect(page.nextCursor, isNull);
    });

    test('turning Memory off and on round-trips', () async {
      final backend = DemoMemoryBackend();
      final off = MemoryStatus.fromJson(
        await backend.request({'op': 'settings', 'enabled': false}),
      );
      expect(off.enabled, isFalse);
      final on = MemoryStatus.fromJson(
        await backend.request({'op': 'settings', 'enabled': true}),
      );
      expect(on.enabled, isTrue);
    });

    test('an op the sample cannot do is refused in the sample words', () {
      expect(
        () => DemoMemoryBackend().request({'op': 'recover'}),
        throwsA(
          isA<MemoryException>().having(
            (e) => e.code,
            'code',
            kDemoRefusalCode,
          ),
        ),
      );
    });
  });

  test('the sample answers Memory and starts from the seed on each entry', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(demoModeProvider.notifier).set(true);
    final request = container.read(
      memoryRequestProvider(const MemoryTarget.machine()),
    );
    final first = (await _list(container.read(demoMemoryBackendProvider)))
        .first;
    await request({'op': 'forget', 'id': first.id});
    expect(
      (await request(const MemoryFilter().request(0)))['results'],
      isNot(contains(predicate<Map>((r) => r['id'] == first.id))),
    );

    container.read(demoModeProvider.notifier).set(false);
    container.read(demoModeProvider.notifier).set(true);
    expect(
      (await _list(container.read(demoMemoryBackendProvider))).map((r) => r.id),
      contains(first.id),
    );
  });

  testWidgets('entering from Memory lands on the sample memories', (
    tester,
  ) async {
    final container = await pumpDemoApp(
      tester,
      enterDemo: true,
      extraOverrides: _zone,
    );
    enterDemoMemory(container);
    await _settle(tester);

    expect(find.byType(DemoHome), findsOneWidget);
    expect(find.byType(MemoryScreen), findsOneWidget);
    expect(
      find.textContaining('Coupon codes are case-insensitive'),
      findsWidgets,
    );
  });

  testWidgets('the drawer Memory row is live inside the sample project', (
    tester,
  ) async {
    final container = await demoContainer(extraOverrides: _zone);
    container.read(demoModeProvider.notifier).set(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const Scaffold(body: ProjectsDrawer()),
        ),
      ),
    );
    await tester.pump();

    final row = find.widgetWithText(AbListRow, 'Memory');
    expect(tester.widget<AbListRow>(row).enabled, isTrue);
    await tester.tap(row);
    await tester.pump();
    expect(container.read(workbenchSurfaceProvider), WorkbenchSurface.memory);
  });
}
