import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_search_field.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/widgets/memory/memory_edit_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/toast_host.dart';

const _machine = MemoryTarget.machine();

class _Catalog extends AgentCatalogNotifier {
  @override
  Map<String, AgentDescriptor> build() => const {
    'claude-code': AgentDescriptor(
      tool: 'claude-code',
      label: 'Claude Code',
      chatCapable: true,
      judgeCapable: false,
      handlerTerminal: false,
      handlerChat: false,
    ),
  };
}

Map<String, dynamic> statusJson({
  bool available = true,
  bool enabled = true,
  bool paused = false,
  String search = 'ready',
  String recovery = 'ready',
  int pending = 0,
  int failed = 0,
  List<Map<String, dynamic>> failures = const [],
}) => {
  'available': available,
  'enabled': enabled,
  'paused': paused,
  'project_paused': false,
  'search_status': search,
  'recovery_status': recovery,
  'pending_operations': pending,
  'failed_operations': failed,
  'failures': failures,
};

Map<String, dynamic> rec(
  String id, {
  String? content,
  String project = 'p1',
  String type = 'note',
  String scope = 'project',
}) => {
  'id': id,
  'content': content ?? 'Content of $id',
  'memory_type': type,
  'scope': scope,
  'project_id': project,
  if (scope == 'task') 'task_id': 'session-0001',
  'applicability': 'Windows only',
  'evidence': ['src/a.dart'],
  'source': {'actor': 'agent', 'agent_id': 'claude-code'},
  'lifecycle': 'active',
  'created_at': DateTime.now()
      .subtract(const Duration(days: 2))
      .millisecondsSinceEpoch,
  'updated_at': 1,
};

Map<String, dynamic> projectsJson({bool paused = false}) => {
  'projects': [
    {'project_id': 'p1', 'label': 'antgrid', 'memories': 3, 'paused': paused},
  ],
  'memories': 3,
  'earlier_versions': 0,
};

Map<String, dynamic> pageJson(
  List<Map<String, dynamic>> records, {
  bool hasMore = false,
  int? total,
}) => {
  'results': records,
  'has_more': hasMore,
  'total': total ?? records.length,
};

/// Answers every verb and records what was asked. [hook] sees a request first;
/// a non-null answer wins, and it may throw.
class Fake {
  Fake({Map<String, dynamic>? status, List<Map<String, dynamic>>? records})
    : status = status ?? statusJson(),
      records = records ?? [rec('m1'), rec('m2'), rec('m3')];

  Map<String, dynamic> status;
  Map<String, dynamic> projects = projectsJson();
  List<Map<String, dynamic>> records;
  FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic> request)? hook;
  final calls = <Map<String, dynamic>>[];

  Iterable<Map<String, dynamic>> ops(String op) =>
      calls.where((c) => c['op'] == op);

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    calls.add(request);
    final hooked = await hook?.call(request);
    if (hooked != null) return hooked;
    switch (request['op']) {
      case 'status':
        return status;
      case 'projects':
        return projects;
      case 'list' || 'search':
        return pageJson(records);
      case 'get':
        final record = records.firstWhere((r) => r['id'] == request['id']);
        return {'record': record, 'earlier': <Object>[]};
      case 'settings':
        if (request['enabled'] == true) status = {...status, 'enabled': true};
        return status;
      case 'repair':
        status = {...status, 'search_status': 'ready'};
        return status;
      default:
        return <String, dynamic>{};
    }
  }
}

void useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void useWide(WidgetTester tester) => useSize(tester, const Size(1280, 820));
void useNarrow(WidgetTester tester) => useSize(tester, const Size(390, 844));

Future<void> mount(
  WidgetTester tester,
  Fake fake, {
  String? projectId,
  bool viaOpen = false,
}) async {
  Widget home = MemoryScreen(target: _machine, initialProjectId: projectId);
  if (viaOpen) {
    home = Builder(
      builder: (context) {
        // openMemoryScreen is what a project entry calls.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          unawaited(openMemoryScreen(context, _machine, projectId: projectId));
        });
        return const SizedBox.shrink();
      },
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        memoryRequestProvider(_machine).overrideWithValue(fake.call),
        agentCatalogProvider.overrideWith(_Catalog.new),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        builder: abToastHostBuilder,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// AbSegmented uppercases its labels.
Finder get earlierVersions => find.text('EARLIER VERSIONS');

Finder get searchInput => find.descendant(
  of: find.byType(AbSearchField),
  matching: find.byType(EditableText),
);

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MemoryScreen)));

List<Map<String, dynamic>> listLike(Fake fake) => [
  ...fake.ops('list'),
  ...fake.ops('search'),
];

void main() {
  testWidgets('an unavailable store asks only for status and offers recovery', (
    tester,
  ) async {
    useWide(tester);
    final fake = Fake(status: statusJson(available: false));
    await mount(tester, fake);
    expect(fake.calls, [
      {'op': 'status'},
    ]);
    expect(find.text('Memory unavailable'), findsOneWidget);
    expect(find.text('Retry store recovery'), findsOneWidget);
    await tester.tap(find.text('Retry store recovery'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains(equals({'op': 'repair'})));
  });

  testWidgets('off state turns Memory on', (tester) async {
    useWide(tester);
    final fake = Fake(status: statusJson(enabled: false));
    await mount(tester, fake);
    expect(find.text('Let your agents remember what they learn'), findsOne);
    await tester.tap(find.text('Turn on Memory'));
    await tester.pumpAndSettle();
    expect(
      fake.calls,
      contains(equals({'op': 'settings', 'enabled': true})),
    );
    expect(find.text('Let your agents remember what they learn'), findsNothing);
  });

  testWidgets('a failing turn-on shows the mapped error above the button', (
    tester,
  ) async {
    useWide(tester);
    final fake = Fake(status: statusJson(enabled: false))
      ..hook = (r) {
        if (r['op'] == 'settings') {
          throw const MemoryException('BUSY', 'raw backend words');
        }
        return null;
      };
    await mount(tester, fake);
    await tester.tap(find.text('Turn on Memory'));
    await tester.pumpAndSettle();
    final error = find.text('Memory is busy. Try again in a moment.');
    expect(error, findsOneWidget);
    expect(find.text('raw backend words'), findsNothing);
    expect(
      tester.getTopLeft(error).dy,
      lessThan(tester.getTopLeft(find.text('Turn on Memory')).dy),
    );
  });

  testWidgets('the compact off-state header has no settings gear', (
    tester,
  ) async {
    useNarrow(tester);
    await mount(tester, Fake(status: statusJson(enabled: false)));
    expect(find.text('Turn on Memory'), findsOneWidget);
    expect(find.byTooltip('Memory settings'), findsNothing);
    expect(find.byTooltip('Back'), findsOneWidget);
  });

  group('wide list', () {
    testWidgets('shows the count, meta line and an auto-selected detail', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake);
      expect(find.text('3 memories'), findsOneWidget);
      expect(
        find.text('antgrid  ·  Claude Code  ·  2d ago'),
        findsNWidgets(3),
      );
      expect(find.text('Applies when'), findsOneWidget);
      expect(fake.ops('get').single['id'], 'm1');
      expect(find.text('Saving on'), findsOneWidget);

      await tester.tap(find.text('Content of m2'));
      await tester.pumpAndSettle();
      expect(fake.ops('get').map((c) => c['id']), contains('m2'));
      expect(find.text('Applies when'), findsOneWidget);
    });

    testWidgets('search as you type sends the debounced query', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake);
      expect(find.text('Search'), findsNothing);
      await tester.enterText(searchInput, 'cmake');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        fake.calls,
        contains(
          equals({
            'op': 'search',
            'query': 'cmake',
            'limit': 50,
            'offset': 0,
            'versions': 'current',
          }),
        ),
      );
    });

    testWidgets('versions, kind and project filters shape the request', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake, projectId: 'p1', viaOpen: true);
      expect(fake.ops('list').first['project_id'], 'p1');

      await tester.tap(earlierVersions);
      await tester.pumpAndSettle();
      expect(fake.ops('list').last['versions'], 'earlier');
      expect(fake.ops('list').last['project_id'], 'p1');

      await tester.tap(find.text('All kinds'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Session progress'));
      await tester.pumpAndSettle();
      // The substituted test font makes this label wider than the picker, and
      // AbButton does not ellipsize it without wrapLabel. Real fonts fit.
      tester.takeException();
      expect(fake.ops('list').last['memory_type'], 'task_state');

      // Dismissing the menu is not a choice.
      final before = fake.calls.length;
      await tester.tap(find.text('antgrid').first);
      await tester.pumpAndSettle();
      expect(find.text('All projects'), findsOneWidget);
      await tester.tapAt(const Offset(1270, 810));
      await tester.pumpAndSettle();
      expect(fake.calls.length, before);

      await tester.tap(find.text('antgrid').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All projects'));
      await tester.pumpAndSettle();
      expect(fake.ops('list').last.containsKey('project_id'), isFalse);
      expect(fake.ops('list').last['memory_type'], 'task_state');
    });

    testWidgets('a project with no memories offers Show all projects', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake()
        ..hook = (r) => r['op'] == 'list' && r['project_id'] != null
            ? pageJson(const [])
            : null;
      await mount(tester, fake, projectId: 'p1');
      expect(find.text('No memories for antgrid yet'), findsOneWidget);
      expect(find.text('No memories match'), findsNothing);
      await tester.tap(find.text('Show all projects'));
      await tester.pumpAndSettle();
      expect(fake.ops('list').last.containsKey('project_id'), isFalse);
      expect(find.text('Content of m1'), findsWidgets);
    });

    testWidgets('a paused project reads Saving paused in the pill', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake()..projects = projectsJson(paused: true);
      await mount(tester, fake, projectId: 'p1');
      expect(find.text('Saving paused'), findsOneWidget);
      expect(find.text('Saving on'), findsNothing);
    });

    testWidgets('no results clear every filter but keep versions', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake()
        ..hook = (r) => r['op'] == 'search' ? pageJson(const []) : null;
      await mount(tester, fake, projectId: 'p1');
      await tester.tap(earlierVersions);
      await tester.pumpAndSettle();
      await tester.enterText(searchInput, 'cmake');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('No memories match'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      final last = fake.ops('list').last;
      expect(last['versions'], 'earlier');
      expect(last.containsKey('project_id'), isFalse);
      expect(last.containsKey('memory_type'), isFalse);
      expect(find.text('cmake'), findsNothing);
      expect(
        tester.widget<EditableText>(searchInput).controller.text,
        isEmpty,
      );
    });

    testWidgets('an invalid search shows the error, not an empty result', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake()
        ..hook = (r) {
          if (r['op'] == 'search') {
            throw const MemoryException('INVALID_ARGUMENT', 'raw');
          }
          return null;
        };
      await mount(tester, fake);
      await tester.enterText(searchInput, '***');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.textContaining("didn't understand"), findsOneWidget);
      expect(find.text('No memories match'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('Show more pages, and a filter change resets to one page', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake()
        ..hook = (r) {
          if (r['op'] != 'list') return null;
          return switch (r['offset']) {
            0 => pageJson([rec('m1'), rec('m2')], hasMore: true, total: 3),
            // Repeats page 0's last row, as an insert at the head would.
            _ => pageJson([rec('m2'), rec('m3')], total: 3),
          };
        };
      await mount(tester, fake);
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      final offsets = fake.ops('list').map((c) => c['offset']).toList();
      expect(offsets.where((o) => o == 50), hasLength(1));
      expect(offsets.where((o) => o == 0), hasLength(2));
      expect(find.text('Content of m2'), findsOneWidget);
      expect(find.text('Content of m3'), findsOneWidget);

      fake.calls.clear();
      await tester.tap(find.text('All kinds'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preference'));
      await tester.pumpAndSettle();
      final lists = fake.ops('list').toList();
      expect(lists, isNotEmpty);
      expect(lists.every((c) => c['memory_type'] == 'preference'), isTrue);
      expect(lists.every((c) => c['offset'] == 0), isTrue);
    });
  });

  group('problems', () {
    testWidgets('broken search can be rebuilt and disables the field', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake(status: statusJson(search: 'needs_repair'));
      await mount(tester, fake);
      expect(
        find.text(
          "Search is broken, so it's switched off. You can still browse every memory below.",
        ),
        findsOneWidget,
      );
      expect(find.text("Search is off until it's rebuilt"), findsOneWidget);
      expect(tester.widget<AbTextField>(find.byType(AbTextField)).enabled, false);
      expect(find.byType(AbSearchField), findsNothing);
      expect(find.text('Needs attention'), findsOneWidget);
      await tester.tap(find.text('Rebuild search'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains(equals({'op': 'repair'})));
      expect(find.text('Search rebuilt'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('an active query falls back to browsing when search breaks', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake);
      await tester.enterText(searchInput, 'cmake');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(fake.ops('search'), isNotEmpty);

      fake.status = statusJson(search: 'needs_repair');
      fake.hook = (r) {
        if (r['op'] == 'search') {
          throw const MemoryException('SEARCH_UNAVAILABLE', 'raw');
        }
        return null;
      };
      fake.calls.clear();
      containerOf(tester).invalidate(memoryStatusProvider(_machine));
      await tester.pumpAndSettle();
      final pages = listLike(fake);
      expect(pages, isNotEmpty);
      expect(pages.last['op'], 'list');
      expect(pages.last.containsKey('query'), isFalse);
      expect(find.textContaining('Search is off until'), findsWidgets);
      expect(find.textContaining("didn't understand"), findsNothing);
      expect(find.text('Content of m1'), findsWidgets);
    });

    testWidgets(
      'problem lines read search, then pending, then conflict; pending has no button',
      (tester) async {
      useWide(tester);
      final fake = Fake(
        status: statusJson(
          search: 'needs_repair',
          pending: 1,
          failed: 1,
          failures: [
            {'code': 'CONFLICT', 'target_id': 'm1', 'latest_id': 'm2'},
          ],
        ),
      );
      await mount(tester, fake);
      final search = find.textContaining('Search is broken');
      final pending = find.textContaining('1 save is waiting');
      final conflict = find.textContaining('1 save was skipped');
      expect(pending, findsOneWidget);
      expect(conflict, findsOneWidget);
      final y = [search, pending, conflict]
          .map((f) => tester.getTopLeft(f).dy)
          .toList();
      expect(y[0], lessThan(y[1]));
      expect(y[1], lessThan(y[2]));
      // Rebuild search and Show memory are the only buttons.
      expect(find.text('Rebuild search'), findsOneWidget);
      expect(find.text('Show memory'), findsOneWidget);
    });

    testWidgets('a pending-only status has a line and no action', (
      tester,
    ) async {
      useWide(tester);
      await mount(tester, Fake(status: statusJson(pending: 2)));
      expect(find.textContaining('2 saves are waiting'), findsOneWidget);
      expect(find.text('Show memory'), findsNothing);
      expect(find.text('Rebuild search'), findsNothing);
      expect(find.text('Saving on'), findsOneWidget);
    });

    testWidgets('Show memory acknowledges, clears the search and opens it', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake(
        status: statusJson(
          failed: 1,
          failures: [
            {'code': 'CONFLICT', 'target_id': 'old', 'latest_id': 'm2'},
          ],
        ),
      );
      fake.hook = (r) {
        if (r['op'] == 'dismiss') {
          fake.status = statusJson();
          return <String, dynamic>{};
        }
        return null;
      };
      await mount(tester, fake);
      await tester.enterText(searchInput, 'cmake');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      fake.calls.clear();
      await tester.tap(find.text('Show memory'));
      await tester.pumpAndSettle();
      expect(fake.calls.first, {'op': 'dismiss', 'target_id': 'old'});
      final gets = fake.ops('get').map((c) => c['id']).toList();
      expect(gets, contains('m2'));
      expect(
        tester.widget<EditableText>(searchInput).controller.text,
        isEmpty,
      );
      expect(find.text('Show memory'), findsNothing);
    });

    testWidgets('a conflict whose memory is gone unpins and refreshes status', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake(
        status: statusJson(
          failed: 1,
          failures: [
            {'code': 'CONFLICT', 'target_id': 'old', 'latest_id': 'gone'},
          ],
        ),
      );
      fake.hook = (r) {
        if (r['op'] == 'get' && r['id'] == 'gone') {
          throw const MemoryException('NOT_FOUND', 'raw');
        }
        return null;
      };
      await mount(tester, fake);
      fake.calls.clear();
      await tester.tap(find.text('Show memory'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('This memory was forgotten.'), findsWidgets);
      expect(find.text('Retry'), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      // Unpinned: the first listed memory is shown again, and status was
      // asked for again.
      expect(fake.ops('status'), isNotEmpty);
      expect(fake.ops('get').last['id'], 'm1');
      expect(find.text('Applies when'), findsOneWidget);
    });
  });

  group('keyboard', () {
    testWidgets('ArrowDown moves the selection and Ctrl+F finds', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(fake.ops('get').last['id'], 'm2');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(searchInput).focusNode.hasFocus, true);
    });

    testWidgets('ArrowDown in the edit form keeps the form and its text', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      final content = find
          .descendant(
            of: find.byType(MemoryEditForm),
            matching: find.byType(EditableText),
          )
          .first;
      await tester.enterText(content, 'Edited content');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.byType(MemoryEditForm), findsOneWidget);
      expect(
        tester.widget<EditableText>(content).controller.text,
        'Edited content',
      );
      expect(fake.ops('get').map((c) => c['id']), isNot(contains('m2')));
    });

    testWidgets('ArrowDown in the search field leaves the selection', (
      tester,
    ) async {
      useWide(tester);
      final fake = Fake();
      await mount(tester, fake);
      await tester.showKeyboard(searchInput);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(fake.ops('get').map((c) => c['id']), isNot(contains('m2')));
      expect(tester.widget<EditableText>(searchInput).focusNode.hasFocus, true);
    });
  });

  testWidgets('forgetting the first row moves on to the next memory', (
    tester,
  ) async {
    useWide(tester);
    var forgotten = false;
    final fake = Fake()
      ..hook = (r) {
        if (r['op'] == 'forget') {
          forgotten = true;
          return <String, dynamic>{};
        }
        // The list reload lags the forget, so m1 is still listed.
        if (forgotten && r['op'] == 'get' && r['id'] == 'm1') {
          throw const MemoryException('FORGOTTEN', 'raw');
        }
        return null;
      };
    await mount(tester, fake);
    expect(fake.ops('get').last['id'], 'm1');
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(find.text('Forget this memory?'), findsWidgets);
    await tester.tap(find.text('Forget').last);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Forget this memory?'), findsNothing);
    expect(find.text('This memory was forgotten.'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Forget this memory?'), findsNothing);
    expect(find.text('This memory was forgotten.'), findsNothing);
    expect(find.text('Content of m1'), findsNothing);
    expect(fake.ops('get').last['id'], 'm2');
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a search still debouncing is dropped by Clear filters', (
    tester,
  ) async {
    useWide(tester);
    final fake = Fake()
      ..hook = (r) => r['op'] == 'search' ? pageJson(const []) : null;
    await mount(tester, fake);
    await tester.enterText(searchInput, 'cmake');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No memories match'), findsOneWidget);
    await tester.enterText(searchInput, 'cmakes');
    await tester.pump();
    await tester.tap(find.text('Clear filters'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(fake.ops('search').map((c) => c['query']), isNot(contains('cmakes')));
    expect(
      fake.calls.lastWhere((c) => c['op'] == 'list' || c['op'] == 'search')['op'],
      'list',
    );
    expect(tester.widget<EditableText>(searchInput).controller.text, isEmpty);
  });
}
