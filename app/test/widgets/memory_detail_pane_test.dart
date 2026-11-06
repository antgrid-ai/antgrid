import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/widgets/memory/memory_detail_pane.dart';
import 'package:antgrid/widgets/memory/memory_record_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

const _target = MemoryTarget.machine();

Map<String, dynamic> _record({
  String id = 'mem_7f3a91c2',
  String content = 'Delete app/build/windows after a failed CMake configure.',
  String memoryType = 'observation',
  String scope = 'project',
  String applicability = 'Windows desktop builds',
  List<String> evidence = const ['app/windows/CMakeLists.txt'],
  String actor = 'agent',
  String lifecycle = 'active',
  String? supersededBy,
  String? taskId,
  String? checkoutId,
  int? createdAt,
}) => {
  'id': id,
  'content': content,
  'memory_type': memoryType,
  'scope': scope,
  'project_id': 'antgrid',
  'applicability': applicability,
  'evidence': evidence,
  'source': {'actor': actor, 'agent_id': 'codex'},
  'lifecycle': lifecycle,
  'created_at': createdAt ?? DateTime.now().millisecondsSinceEpoch,
  'updated_at': createdAt ?? DateTime.now().millisecondsSinceEpoch,
  'task_id': ?taskId,
  'checkout_id': ?checkoutId,
  'superseded_by': ?supersededBy,
};

Map<String, dynamic> _status(String search) => {
  'available': true,
  'enabled': true,
  'paused': false,
  'project_paused': false,
  'search_status': search,
  'recovery_status': 'ready',
  'pending_operations': 0,
};

class _Harness {
  final calls = <Map<String, dynamic>>[];
  final saved = <String>[];
  var forgotten = 0;
  Object? forgetError;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<_Harness> pumpPane(
    WidgetTester tester, {
    Map<String, dynamic>? record,
    List<Map<String, dynamic>> earlier = const [],
    bool earlierHasMore = false,
    String search = 'ready',
    Size size = const Size(1280, 820),
    bool compact = false,
    bool page = false,
    double keyboard = 0,
    Object? forgetError,
  }) async {
    final h = _Harness()..forgetError = forgetError;
    final rec = record ?? _record();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    Future<Map<String, dynamic>> request(Map<String, dynamic> r) async {
      h.calls.add(r);
      switch (r['op']) {
        case 'status':
          return _status(search);
        case 'projects':
          return {
            'projects': [
              {'project_id': 'antgrid', 'label': 'antgrid', 'memories': 1},
            ],
            'memories': 1,
            'earlier_versions': earlier.length,
          };
        case 'get':
          return {
            'record': rec,
            'earlier': earlier,
            'earlier_has_more': earlierHasMore,
          };
        case 'save':
          return {'id': 'mem_new'};
        case 'forget':
          if (h.forgetError != null) throw h.forgetError!;
          return {};
      }
      return {};
    }

    final Widget body = page
        ? MemoryRecordDetails(target: _target, id: rec['id'] as String)
        : Scaffold(
            body: _host(
              compact: compact,
              child: MemoryDetailPane(
                target: _target,
                id: rec['id'] as String,
                compact: compact,
                onSaved: h.saved.add,
                onForgotten: () => h.forgotten++,
              ),
            ),
          );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryRequestProvider(_target).overrideWithValue(request),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          builder: abToastHostBuilder,
          home: body,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  Finder button(String label) => find.widgetWithText(AbButton, label);
  VoidCallback? tapOf(WidgetTester tester, String label) =>
      tester.widget<AbButton>(button(label)).onTap;

  Future<void> tapButton(WidgetTester tester, String label) async {
    await tester.ensureVisible(button(label));
    await tester.tap(button(label));
    await tester.pumpAndSettle();
  }

  bool focusIsInside(Finder container) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return find
        .descendant(
          of: container,
          matching: find.byElementPredicate((e) => e == context),
        )
        .evaluate()
        .isNotEmpty;
  }

  Future<void> pressEsc(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets('tags show kind, scope and lifecycle', (tester) async {
    await pumpPane(tester);
    expect(find.text('Observation'), findsOneWidget);
    expect(find.text('Project memory'), findsOneWidget);
    expect(find.text('Replaced by a newer version'), findsNothing);
  });

  testWidgets('a replaced memory carries the filled lifecycle tag', (
    tester,
  ) async {
    await pumpPane(
      tester,
      record: _record(lifecycle: 'superseded', supersededBy: 'mem_newer'),
    );
    expect(find.text('Replaced by a newer version'), findsOneWidget);
    expect(button('Edit'), findsNothing);
  });

  testWidgets('applies-when falls back by scope', (tester) async {
    await pumpPane(tester, record: _record(applicability: ''));
    expect(
      find.text('Not stated. Agents treat it as a general note for antgrid.'),
      findsOneWidget,
    );
  });

  testWidgets('applies-when for a session memory names the session', (
    tester,
  ) async {
    await pumpPane(
      tester,
      record: _record(
        applicability: '  ',
        scope: 'task',
        memoryType: 'task_state',
        taskId: 'abcd1234efgh',
      ),
    );
    expect(find.text('Only inside session abcd1234.'), findsOneWidget);
    expect(find.text('Session abcd1234 only'), findsOneWidget);
    expect(find.text('Session progress'), findsOneWidget);
  });

  testWidgets('an uncited memory says so', (tester) async {
    await pumpPane(tester, record: _record(evidence: const []));
    expect(find.text("The agent didn't cite any files."), findsOneWidget);
  });

  testWidgets('a memory saved from the app reads as saved by you', (
    tester,
  ) async {
    await pumpPane(tester, record: _record(actor: 'app'));
    expect(find.text('Saved by you, just now, in antgrid'), findsOneWidget);
  });

  testWidgets('earlier versions are listed under their disclosure', (
    tester,
  ) async {
    await pumpPane(
      tester,
      earlier: [
        _record(id: 'e1', content: 'Older text one'),
        _record(id: 'e2', content: 'Older text two'),
      ],
    );
    expect(find.text('2 earlier versions'), findsOneWidget);
    expect(find.text('Older text one'), findsNothing);
    await tester.tap(find.text('2 earlier versions'));
    await tester.pumpAndSettle();
    expect(find.text('Older text one'), findsOneWidget);
    expect(find.text('Older text two'), findsOneWidget);
  });

  testWidgets('no disclosure when there are no earlier versions', (
    tester,
  ) async {
    await pumpPane(tester);
    expect(find.textContaining('earlier version'), findsNothing);
  });

  testWidgets('technical details list the ids', (tester) async {
    await pumpPane(tester, record: _record(actor: 'app'));
    expect(find.text('Memory id'), findsNothing);
    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    for (final label in [
      'Memory id',
      'Project id',
      'Session',
      'Checkout',
      'Saved by',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('mem_7f3a91c2'), findsOneWidget);
    expect(find.text('antgrid'), findsWidgets);
    expect(find.text('Any session'), findsOneWidget);
    expect(find.text('Any checkout'), findsOneWidget);
    expect(find.text('you (app)'), findsOneWidget);
  });

  testWidgets('Keep it closes the forget confirm without sending anything', (
    tester,
  ) async {
    final h = await pumpPane(tester);
    await tapButton(tester, 'Forget');
    expect(find.text('Forget this memory?'), findsOneWidget);
    await tapButton(tester, 'Keep it');
    expect(find.text('Forget this memory?'), findsNothing);
    expect(h.calls.where((c) => c['op'] == 'forget'), isEmpty);
    expect(h.forgotten, 0);
  });

  testWidgets('confirming forget sends it, toasts and reports', (tester) async {
    final h = await pumpPane(tester);
    await tapButton(tester, 'Forget');
    await tapButton(tester, 'Forget');
    expect(
      h.calls.where((c) => c['op'] == 'forget'),
      [
        {'op': 'forget', 'id': 'mem_7f3a91c2'},
      ],
    );
    expect(find.text('Memory forgotten'), findsOneWidget);
    expect(h.forgotten, 1);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a failed forget stays open with a banner', (tester) async {
    final h = await pumpPane(
      tester,
      forgetError: const MemoryException('BUSY', 'x'),
    );
    await tapButton(tester, 'Forget');
    await tapButton(tester, 'Forget');
    expect(find.text('Memory is busy. Try again in a moment.'), findsOneWidget);
    expect(find.text('Forget this memory?'), findsOneWidget);
    expect(h.forgotten, 0);
  });

  testWidgets('a forget whose cleanup failed still counts as forgotten', (
    tester,
  ) async {
    final h = await pumpPane(
      tester,
      forgetError: const MemoryException('CLEANUP_FAILED', 'x'),
    );
    await tapButton(tester, 'Forget');
    await tapButton(tester, 'Forget');
    expect(h.forgotten, 1);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Esc after Forget closes the confirm and refocuses Forget', (
    tester,
  ) async {
    await pumpPane(tester);
    await tester.tap(button('Forget'));
    await tester.pumpAndSettle();
    expect(find.text('Forget this memory?'), findsOneWidget);
    expect(focusIsInside(button('Keep it')), isTrue);
    await pressEsc(tester);
    expect(find.text('Forget this memory?'), findsNothing);
    expect(focusIsInside(button('Forget')), isTrue);
  });

  testWidgets('a replaced memory warns the whole chain goes', (tester) async {
    await pumpPane(
      tester,
      record: _record(lifecycle: 'superseded', supersededBy: 'mem_newer'),
    );
    await tapButton(tester, 'Forget');
    expect(
      find.text(
        "Agents won't recall it again, and every other version of it, including the current one, is deleted too. Your files and conversations aren't touched.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('a current memory warns its earlier versions go', (tester) async {
    await pumpPane(tester);
    await tapButton(tester, 'Forget');
    expect(
      find.text(
        "Agents won't recall it again, and its earlier versions are deleted too. Your files and conversations aren't touched.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('Esc after Edit leaves edit mode and refocuses Edit', (
    tester,
  ) async {
    await pumpPane(tester);
    await tester.tap(button('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    await pressEsc(tester);
    expect(find.text('Save changes'), findsNothing);
    expect(button('Edit'), findsOneWidget);
    expect(focusIsInside(button('Edit')), isTrue);
  });

  testWidgets('Cancel leaves edit mode without a request', (tester) async {
    final h = await pumpPane(tester);
    await tapButton(tester, 'Edit');
    await tapButton(tester, 'Cancel');
    expect(find.text('Save changes'), findsNothing);
    expect(h.calls.where((c) => c['op'] == 'save'), isEmpty);
  });

  testWidgets('the tags stay visible in edit mode', (tester) async {
    await pumpPane(tester);
    await tapButton(tester, 'Edit');
    expect(find.text('Observation'), findsOneWidget);
    expect(find.text('Project memory'), findsOneWidget);
  });

  testWidgets('Edit is disabled until search is ready', (tester) async {
    await pumpPane(tester, search: 'rebuilding');
    expect(tapOf(tester, 'Edit'), isNull);
    await tester.tap(button('Edit'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('eight sources disable Add; removing one re-enables it', (
    tester,
  ) async {
    final sources = [for (var i = 0; i < 8; i++) 'docs/page$i.md'];
    await pumpPane(tester, record: _record(evidence: sources));
    await tapButton(tester, 'Edit');
    expect(
      find.text('That’s the limit of 8 sources. Remove one to add another.'),
      findsOneWidget,
    );
    expect(tapOf(tester, 'Add'), isNull);
    await tester.ensureVisible(find.byTooltip('Remove docs/page3.md'));
    await tester.tap(find.byTooltip('Remove docs/page3.md'));
    await tester.pumpAndSettle();
    expect(
      find.text('Files or doc sections that back this memory up.'),
      findsOneWidget,
    );
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(2), 'docs/new.md');
    await tester.pumpAndSettle();
    expect(tapOf(tester, 'Add'), isNotNull);
    await tapButton(tester, 'Add');
    expect(find.byTooltip('Remove docs/new.md'), findsOneWidget);
    expect(tapOf(tester, 'Add'), isNull);
  });

  testWidgets('Save sends the correction, toasts and reports the new id', (
    tester,
  ) async {
    final h = await pumpPane(
      tester,
      record: _record(
        scope: 'task',
        memoryType: 'task_state',
        taskId: 'abcd1234efgh',
        checkoutId: 'checkout-1',
      ),
    );
    await tapButton(tester, 'Edit');
    expect(tapOf(tester, 'Save changes'), isNull);
    await tester.enterText(find.byType(EditableText).first, 'Fixed text');
    await tester.pumpAndSettle();
    await tapButton(tester, 'Save changes');
    final save = h.calls.singleWhere((c) => c['op'] == 'save');
    expect(save['operation_key'], isA<String>());
    final body = save['save'] as Map;
    expect(body['content'], 'Fixed text');
    expect(body['scope'], 'task');
    expect(body['restrict_to_checkout'], true);
    expect(body['supersedes'], 'mem_7f3a91c2');
    expect(body.containsKey('task_id'), false);
    expect(find.text('Changes saved'), findsOneWidget);
    expect(h.saved, ['mem_new']);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('compact edit bar offers Save changes and Cancel only', (
    tester,
  ) async {
    await pumpPane(tester, compact: true, size: const Size(390, 844));
    expect(button('Edit'), findsOneWidget);
    expect(button('Forget'), findsOneWidget);
    await tapButton(tester, 'Edit');
    expect(button('Save changes'), findsOneWidget);
    expect(button('Cancel'), findsOneWidget);
    expect(button('Forget'), findsNothing);
    expect(button('Edit'), findsNothing);
  });

  testWidgets('compact forget confirm puts Keep it in the bar', (tester) async {
    await pumpPane(tester, compact: true, size: const Size(390, 844));
    await tapButton(tester, 'Forget');
    expect(find.text('Forget this memory?'), findsOneWidget);
    expect(button('Keep it'), findsOneWidget);
    expect(button('Edit'), findsNothing);
    await tapButton(tester, 'Keep it');
    expect(button('Edit'), findsOneWidget);
  });

  group('layout', () {
    final long = List.filled(60, 'A very long sentence about builds.').join(' ');
    final earlier = [
      for (var i = 0; i < 20; i++) _record(id: 'e$i', content: '$long $i'),
    ];

    Future<void> expandAll(WidgetTester tester) async {
      await tester.ensureVisible(find.textContaining('20 earlier versions'));
      await tester.tap(find.textContaining('20 earlier versions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Technical details'));
      await tester.tap(find.text('Technical details'));
      await tester.pumpAndSettle();
    }

    testWidgets('wide, long memory with everything expanded', (tester) async {
      await pumpPane(
        tester,
        record: _record(
          content: long,
          evidence: [for (var i = 0; i < 8; i++) 'docs/long/path/page$i.md'],
        ),
        earlier: earlier,
      );
      await expandAll(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone page, long memory with everything expanded', (
      tester,
    ) async {
      await pumpPane(
        tester,
        record: _record(
          content: long,
          evidence: [for (var i = 0; i < 8; i++) 'docs/long/path/page$i.md'],
        ),
        earlier: earlier,
        page: true,
        size: const Size(390, 844),
      );
      await expandAll(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone page, edit mode with 8 sources and the keyboard up', (
      tester,
    ) async {
      await pumpPane(
        tester,
        record: _record(
          content: long,
          evidence: [for (var i = 0; i < 8; i++) 'docs/long/path/page$i.md'],
        ),
        page: true,
        size: const Size(390, 844),
        keyboard: 300,
      );
      await tapButton(tester, 'Edit');
      expect(find.byTooltip('Remove docs/long/path/page7.md'), findsOneWidget);
      expect(button('Save changes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a forgotten memory shows the gone state and reports once', (
    tester,
  ) async {
    var gone = 0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 820);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryRequestProvider(_target).overrideWithValue((r) async {
            if (r['op'] == 'get') {
              throw const MemoryException('FORGOTTEN', 'gone');
            }
            return r['op'] == 'projects'
                ? {'projects': <Object>[], 'memories': 0, 'earlier_versions': 0}
                : _status('ready');
          }),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          builder: abToastHostBuilder,
          home: Scaffold(
            body: MemoryDetailPane(
              target: _target,
              id: 'x',
              onSaved: (_) {},
              onForgotten: () {},
              onGone: () => gone++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This memory was forgotten.'), findsOneWidget);
    expect(find.text('Pick another memory from the list.'), findsOneWidget);
    expect(button('Retry'), findsNothing);
    expect(gone, 1);
  });
}

/// The wide pane does not scroll itself, so its host does; the compact pane
/// needs a bounded height for its fixed action bar.
Widget _host({required bool compact, required Widget child}) => compact
    ? child
    : SingleChildScrollView(padding: const EdgeInsets.all(24), child: child);
