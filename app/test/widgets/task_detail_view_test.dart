import 'dart:async';
import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/models/task.dart';
import 'package:antgrid/widgets/tasks/task_detail_view.dart';
import 'package:antgrid/widgets/tasks/task_provenance_view.dart';
import 'package:antgrid/widgets/tasks/task_status_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _task({
  int number = 42,
  String title = 'Fix the drawer',
  String body = 'It jitters on resize.',
  String status = 'in_progress',
  List<Map<String, Object?>> labels = const [
    {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a'},
  ],
  String source = 'local',
  String? externalProvider,
  String? externalId,
  String? externalKey,
  String? externalUrl,
  String? syncState,
  Map<String, Object?>? conflict,
  Map<String, Object?>? pushBlocked,
  List<Map<String, Object?>> otherAssignees = const [],
  String? projectId,
}) => {
  'number': number,
  'projectId': projectId,
  'title': title,
  'body': body,
  'status': status,
  'priority': 1,
  'sortKey': 'm',
  'source': source,
  'externalProvider': externalProvider,
  'externalId': externalId,
  'externalKey': externalKey,
  'externalUrl': externalUrl,
  'syncState': syncState,
  'conflict': conflict,
  'pushBlocked': pushBlocked,
  'assignee': const {'kind': 'member', 'userId': 'u-1'},
  'otherAssignees': otherAssignees,
  'labels': labels,
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-02T11:30:00.000Z',
};

/// Deliberately unlike the task's own title, so a value under test can never
/// be satisfied by the header rendering the same string.
const _titleConflict = {
  'field': 'title',
  'localValue': 'Fix the drawer, mine',
  'remoteValue': 'Fix the drawer, theirs',
  'at': '2026-08-18T09:00:00.000Z',
};

ProviderContainer _container(
  MockClient client, {
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      tasksApiProvider.overrideWithValue(
        TasksApi(
          licenseApiUrl: 'https://api.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
      taskAssigneeCandidatesProvider.overrideWithValue(const [
        TaskAssigneeCandidate(userId: 'u-1', displayName: 'me@antgrid.ai'),
      ]),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The source block sits between the attributes and the description, so the
/// default 800x600 surface can push the lines under test off the bottom.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: const Scaffold(body: TaskDetailView(number: 42)),
      ),
    ),
  );
}

MockClient _serving(
  Map<String, Object?> task, {
  void Function(http.Request)? on,
  List<Map<String, Object?>> targets = const [],
}) {
  return MockClient((req) async {
    on?.call(req);
    if (req.url.path == '/labels') {
      return http.Response('{"labels":[]}', 200);
    }
    if (req.url.path == '/tasks/publish-targets') {
      return http.Response(jsonEncode({'targets': targets}), 200);
    }
    if (req.method == 'GET' && req.url.path == '/tasks') {
      return http.Response(
        jsonEncode({
          'tasks': [task],
        }),
        200,
      );
    }
    return http.Response(jsonEncode({'task': task}), 200);
  });
}

void main() {
  testWidgets('a fetch in flight shows loading, not "no longer exists"', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    final container = _container(MockClient((_) => gate.future));
    await _pump(tester, container);
    await tester.pump();

    expect(find.text('Loading task…'), findsOneWidget);
    expect(find.text('This task no longer exists'), findsNothing);

    gate.complete(http.Response('{"tasks":[]}', 200));
    await tester.pumpAndSettle();
  });

  testWidgets('a refusal renders its copy and a retry', (tester) async {
    final container = _container(
      MockClient((_) async => http.Response('{"error":"NO_ACCOUNT"}', 403)),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('belongs to no Antgrid account'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a task renders its ref, title, status, labels and body', (
    tester,
  ) async {
    final container = _container(_serving(_task()));
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('ANT-42'), findsOneWidget);
    expect(find.text('Fix the drawer'), findsOneWidget);
    expect(find.byType(TaskStatusPill), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('bug'), findsOneWidget);
    expect(find.textContaining('It jitters on resize.'), findsOneWidget);
  });

  testWidgets('a blocked agent is spelled out above the brief', (tester) async {
    final container = _container(
      _serving(_task()),
      overrides: [
        taskRunPresenceProvider.overrideWithValue(const {
          42: TaskRunPresence(
            status: AgentWorkStatus.attention,
            sessionName: 'drawer-fix',
            machineName: 'workstation',
          ),
        }),
      ],
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('Waiting on you'), findsOneWidget);
    expect(find.text('drawer-fix · workstation'), findsOneWidget);
  });

  testWidgets('with no launcher, Start session is dead and says why', (
    tester,
  ) async {
    final container = _container(_serving(_task()));
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('Start session'), findsOneWidget);
    expect(
      find.text('Starting a session from a task is not wired up yet.'),
      findsOneWidget,
    );
  });

  testWidgets('a launcher that refuses renders its own reason verbatim', (
    tester,
  ) async {
    final container = _container(
      _serving(_task()),
      overrides: [taskLauncherProvider.overrideWithValue(_BlockedLauncher())],
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('workstation is offline.'), findsOneWidget);
  });

  testWidgets('the title edits in place and PATCHes by number', (tester) async {
    final seen = <String>[];
    final container = _container(
      _serving(
        _task(),
        on: (req) => seen.add('${req.method} ${req.url.path} ${req.body}'),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fix the drawer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'Renamed');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      seen.where((s) => s.startsWith('PATCH /tasks/42')),
      isNotEmpty,
    );
    expect(seen.last, contains('"title":"Renamed"'));
  });

  testWidgets('an imported task names its provider and offers the issue', (
    tester,
  ) async {
    _tall(tester);
    final container = _container(
      _serving(
        _task(
          source: 'github',
          externalProvider: 'github',
          externalId: 'I_kwDOB1x2y3z4',
          externalKey: 'o/r#88',
          externalUrl: 'https://github.com/o/r/issues/88',
        ),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('Imported from GitHub'), findsOneWidget);
    expect(find.text('o/r#88'), findsOneWidget);
    // The opaque provider handle is the one thing on this block that must
    // never reach the user.
    expect(find.text('I_kwDOB1x2y3z4'), findsNothing);
    expect(find.text('Open issue'), findsOneWidget);
    expect(
      find.text('The description below was written outside your account.'),
      findsOneWidget,
    );
  });

  testWidgets('with no issue URL the affordance is absent, not dead', (
    tester,
  ) async {
    _tall(tester);
    final container = _container(
      _serving(_task(source: 'github', externalProvider: 'github')),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('Imported from GitHub'), findsOneWidget);
    expect(find.text('Open issue'), findsNothing);
  });

  testWidgets('a task written in Antgrid gets no source block', (tester) async {
    _tall(tester);
    final container = _container(_serving(_task()));
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(TaskProvenanceBlock), findsNothing);
    expect(find.textContaining('Imported from'), findsNothing);
  });

  // Which side won, and the way out, belong to the conflict block below —
  // the Source block only states that it happened.
  testWidgets('a sync conflict is named without claiming an outcome', (
    tester,
  ) async {
    _tall(tester);
    final container = _container(
      _serving(
        _task(
          source: 'github',
          externalProvider: 'github',
          syncState: 'conflict',
        ),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(
      find.text('Edited here and on GitHub at the same time.'),
      findsOneWidget,
    );
  });

  // The raw wire spellings (`github`, `conflict`) were what the Details block
  // used to print; the Source block is the only answer now.
  testWidgets('the details block no longer restates provenance raw', (
    tester,
  ) async {
    _tall(tester);
    final container = _container(
      _serving(
        _task(
          source: 'github',
          externalProvider: 'github',
          syncState: 'conflict',
          externalUrl: 'https://github.com/o/r/issues/88',
        ),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('github'), findsNothing);
    expect(find.text('conflict'), findsNothing);
    expect(find.text('https://github.com/o/r/issues/88'), findsNothing);
  });

  testWidgets('Open issue hands the URL to the browser', (tester) async {
    String? opened;
    final task = Task.fromJson(
      _task(
        source: 'github',
        externalProvider: 'github',
        externalUrl: 'https://github.com/o/r/issues/88',
      ),
    )!;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: TaskProvenanceBlock(
            task: task,
            onOpenUrl: (_, url) async => opened = url,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open issue'));
    await tester.pumpAndSettle();

    expect(opened, 'https://github.com/o/r/issues/88');
  });

  // The row can only afford a count, so the sheet is the only place the other
  // nine assignees GitHub allows are ever named.
  testWidgets('co-assignees are named under the chosen one', (tester) async {
    _tall(tester);
    final container = _container(
      _serving(
        _task(
          source: 'github',
          externalProvider: 'github',
          otherAssignees: const [
            {'kind': 'external', 'externalId': '5', 'login': 'octocat'},
          ],
        ),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('Also on GitHub'), findsOneWidget);
    expect(find.text('@octocat'), findsOneWidget);
  });

  // Display only: the reassign picker is the attribute row's, and a co-assignee
  // has no Antgrid identity to reassign to anyway.
  testWidgets('a co-assignee is not a second reassign control', (tester) async {
    _tall(tester);
    final container = _container(
      _serving(
        _task(
          source: 'github',
          externalProvider: 'github',
          otherAssignees: const [
            {'kind': 'external', 'externalId': '5', 'login': 'octocat'},
          ],
        ),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.text('@octocat'));
    await tester.pumpAndSettle();

    expect(find.text('Assignee'), findsOneWidget);
    expect(find.text('Unassigned'), findsNothing);
  });

  group('conflicts', () {
    Map<String, Object?> imported({
      List<Map<String, Object?>> fields = const [_titleConflict],
      List<String> labelRemoveWins = const [],
      String status = 'in_progress',
    }) => _task(
      status: status,
      source: 'github',
      externalProvider: 'github',
      syncState: 'conflict',
      conflict: {'fields': fields, 'labelRemoveWins': labelRemoveWins},
    );

    testWidgets('both versions and both ways out are on screen', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(_serving(imported()));
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOneWidget);
      expect(find.text('On GitHub · in place now'), findsOneWidget);
      expect(find.text('Fix the drawer, theirs'), findsOneWidget);
      expect(find.text('Yours · set aside'), findsOneWidget);
      expect(find.text('Fix the drawer, mine'), findsOneWidget);
      expect(find.text('Keep mine'), findsOneWidget);
      // Named from the provider, never a hardcoded GitHub.
      expect(find.text('Keep GitHub’s'), findsOneWidget);
    });

    // The whole point of the block: a status and an assignee are values a
    // person has to compare, not wire shapes. Status is stored in PROVIDER
    // space, so it renders in provider words — `open` covers three Antgrid
    // statuses and picking one would be a guess shown as the user's choice.
    testWidgets('status and assignee read as themselves, not as JSON', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(
        _serving(
          imported(
            status: 'open',
            fields: const [
              {
                'field': 'status',
                'localValue': {'state': 'closed', 'stateReason': 'not_planned'},
                'remoteValue': {'state': 'open'},
              },
              {
                'field': 'assignee',
                'localValue': {
                  'kind': 'external',
                  'externalId': '5',
                  'login': 'octocat',
                },
                'remoteValue': null,
              },
            ],
          ),
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Closed as not planned'), findsOneWidget);
      // Two "Open" on screen would be the header pill and this value; the
      // header shows the Antgrid status, this shows the provider's.
      expect(find.text('Open'), findsNWidgets(2));
      expect(find.textContaining('stateReason'), findsNothing);
      expect(find.text('@octocat'), findsOneWidget);
      // A remote null is a value: that side unassigned the task.
      expect(find.text('Unassigned'), findsOneWidget);
    });

    testWidgets('Keep mine resolves once, and a second tap adds nothing', (
      tester,
    ) async {
      _tall(tester);
      final gate = Completer<http.Response>();
      final resolves = <String>[];
      final task = imported();
      final container = _container(
        MockClient((req) async {
          if (req.url.path == '/labels') {
            return http.Response('{"labels":[]}', 200);
          }
          if (req.url.path == '/tasks/42/conflict/resolve') {
            resolves.add(req.body);
            return gate.future;
          }
          if (req.method == 'GET' && req.url.path == '/tasks') {
            return http.Response(
              jsonEncode({
                'tasks': [task],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'task': task}), 200);
        }),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keep mine'));
      await tester.pump();

      // Both halves of the guard: the button goes dead on the frame after the
      // press, and the handler refuses a tap already delivered behind it.
      expect(
        tester.widget<AbButton>(find.widgetWithText(AbButton, 'Keep mine')).onTap,
        isNull,
      );
      await tester.tap(find.text('Keep mine'), warnIfMissed: false);
      await tester.pump();

      expect(resolves, hasLength(1));
      expect(jsonDecode(resolves.single), {'field': 'title', 'take': 'local'});

      gate.complete(
        http.Response(jsonEncode({'task': _task(source: 'github')}), 200),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('dropped labels are named and acknowledged in one press', (
      tester,
    ) async {
      _tall(tester);
      final resolves = <String>[];
      final task = imported(
        fields: const [],
        labelRemoveWins: const ['needs-triage'],
      );
      final container = _container(
        _serving(task, on: (req) {
          if (req.url.path == '/tasks/42/conflict/resolve') {
            resolves.add(req.body);
          }
        }),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Labels removed'), findsOneWidget);
      expect(find.text('needs-triage'), findsOneWidget);
      expect(find.textContaining('Add them back by hand'), findsOneWidget);
      // One acknowledgement, never a pair: a label restored here would be
      // absent on the provider with nothing to push it back.
      expect(find.text('Keep mine'), findsNothing);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(jsonDecode(resolves.single), {
        'field': 'labels',
        'take': 'remote',
      });
    });

    testWidgets('a task with nothing to settle renders none of it', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(
        _serving(_task(source: 'github', externalProvider: 'github')),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('UNSETTLED CHANGES'), findsNothing);
      expect(find.text('Keep mine'), findsNothing);
      expect(find.text('Got it'), findsNothing);
    });
  });

  group('push blocks', () {
    Map<String, Object?> stalled({
      List<Map<String, Object?>> fields = const [
        {
          'field': 'title',
          'reason': 'GitHub accepted the title and kept its own.',
          'count': 3,
          'lastAt': '2026-08-18T09:00:00.000Z',
        },
      ],
    }) => _task(
      source: 'github',
      externalProvider: 'github',
      externalId: '7',
      syncState: 'synced',
      pushBlocked: {'fields': fields},
    );

    testWidgets('names the field, the reason and the way out', (tester) async {
      _tall(tester);
      final container = _container(_serving(stalled()));
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOneWidget);
      // Named from the provider, never a hardcoded GitHub.
      expect(
        find.textContaining('stopped reaching GitHub'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The last 3 attempts changed nothing there'),
        findsOneWidget,
      );
      expect(
        find.text('GitHub accepted the title and kept its own.'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    // The wire spelling is what the clear route takes, so an unknown field is
    // printed rather than hidden — hiding it is the one state with no exit.
    testWidgets('a field this build has no label for is still actionable', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(
        _serving(
          stalled(
            fields: const [
              {'field': 'milestone', 'reason': 'unchanged', 'count': 5},
            ],
          ),
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('milestone'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('Try again clears once, and a second tap adds nothing', (
      tester,
    ) async {
      _tall(tester);
      final gate = Completer<http.Response>();
      final clears = <String>[];
      final task = stalled();
      final container = _container(
        MockClient((req) async {
          if (req.url.path == '/labels') {
            return http.Response('{"labels":[]}', 200);
          }
          if (req.url.path == '/tasks/42/push-block/clear') {
            clears.add(req.body);
            return gate.future;
          }
          if (req.method == 'GET' && req.url.path == '/tasks') {
            return http.Response(
              jsonEncode({
                'tasks': [task],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'task': task}), 200);
        }),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Try again'));
      await tester.pump();

      // Both halves of the guard: the button goes dead on the frame after the
      // press, and the handler refuses a tap already delivered behind it.
      expect(
        tester
            .widget<AbButton>(find.widgetWithText(AbButton, 'Try again'))
            .onTap,
        isNull,
      );
      await tester.tap(find.text('Try again'), warnIfMissed: false);
      await tester.pump();

      expect(clears, hasLength(1));
      expect(jsonDecode(clears.single), {'field': 'title'});

      gate.complete(
        http.Response(jsonEncode({'task': _task(source: 'github')}), 200),
      );
      await tester.pumpAndSettle();
    });

    // Clearing one is not entitlement to lift the rest, so the others must
    // still be on screen with their own buttons.
    testWidgets('each stopped field gets its own way back', (tester) async {
      _tall(tester);
      final container = _container(
        _serving(
          stalled(
            fields: const [
              {'field': 'title', 'reason': 'unchanged', 'count': 3},
              {'field': 'labels', 'reason': 'unchanged', 'count': 4},
            ],
          ),
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOneWidget);
      // Two: this block's heading and the attributes row above it, which names
      // the same field for a different reason.
      expect(find.text('Labels'), findsNWidgets(2));
      expect(find.text('Try again'), findsNWidgets(2));
    });

    testWidgets('a task that syncs cleanly renders none of it', (tester) async {
      _tall(tester);
      final container = _container(
        _serving(_task(source: 'github', externalProvider: 'github')),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('STOPPED SYNCING'), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });
  });

  testWidgets('the metadata block stamps created and updated', (tester) async {
    final container = _container(_serving(_task()));
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('Created'), findsOneWidget);
    expect(find.text('Updated'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Antgrid'), findsOneWidget);
  });

  group('publishing', () {
    const target = {
      'id': 'repo-1',
      'owner': 'antgrid',
      'name': 'antgrid',
      'visibility': 'public',
      'publishNewByDefault': false,
    };

    // Absent, never greyed: a dead button on an irreversible action reads as a
    // broken one, and there is nothing the user could do to enable it.
    testWidgets('a task with no project offers no publish', (tester) async {
      _tall(tester);
      final container = _container(
        _serving(_task(), targets: const [target]),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Publish to GitHub'), findsNothing);
    });

    testWidgets('a project with no enabled repo offers no publish', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(_serving(_task(projectId: 'p-1')));
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Publish to GitHub'), findsNothing);
    });

    testWidgets('the confirm names the repo, the text and who can read it', (
      tester,
    ) async {
      _tall(tester);
      final seen = <http.Request>[];
      final container = _container(
        _serving(
          _task(projectId: 'p-1'),
          targets: const [target],
          on: seen.add,
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Publish to GitHub'));
      await tester.pumpAndSettle();

      expect(find.text('Publish ANT-42 to GitHub'), findsOneWidget);
      expect(find.text('antgrid/antgrid'), findsOneWidget);
      expect(
        find.text('This repo is public, so the issue will be public.'),
        findsOneWidget,
      );
      // The exact strings going out, not a summary of them.
      expect(find.text('Fix the drawer'), findsWidgets);
      expect(find.text('It jitters on resize.'), findsWidgets);
      // The standing write channel, said once, where the decision is made.
      expect(
        find.textContaining('sent to the issue without asking again'),
        findsOneWidget,
      );

      await tester.tap(find.text('Create the issue'));
      await tester.pumpAndSettle();

      final post = seen.lastWhere((r) => r.method == 'POST');
      expect(post.url.path, '/tasks/42/publish');
      expect(jsonDecode(post.body), {'repoId': 'repo-1'});
    });

    testWidgets('backing out of the confirm sends nothing', (tester) async {
      _tall(tester);
      final seen = <http.Request>[];
      final container = _container(
        _serving(
          _task(projectId: 'p-1'),
          targets: const [target],
          on: seen.add,
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Publish to GitHub'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(seen.where((r) => r.method == 'POST'), isEmpty);
      // And the action is live again, not stuck behind its own guard.
      expect(
        tester
            .widget<AbButton>(
              find.widgetWithText(AbButton, 'Publish to GitHub'),
            )
            .onTap,
        isNotNull,
      );
    });

    testWidgets('several repos means no default and a dead confirm', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(
        _serving(
          _task(projectId: 'p-1'),
          targets: const [
            target,
            {
              'id': 'repo-2',
              'owner': 'antgrid',
              'name': 'site',
              'visibility': 'private',
              'publishNewByDefault': true,
            },
          ],
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Publish to GitHub'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a repo'), findsOneWidget);
      expect(
        tester
            .widget<AbButton>(find.widgetWithText(AbButton, 'Create the issue'))
            .onTap,
        isNull,
      );
    });

    // Unlink puts the task back in the publishable state, and that is the trap
    // the copy exists to label.
    testWidgets('re-publishing says a NEW issue and names the old one', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(
        _serving(
          _task(
            projectId: 'p-1',
            externalId: 'I_1',
            externalKey: 'o/r#412',
            externalUrl: 'https://github.com/o/r/issues/412',
            syncState: 'unlinked',
          ),
          targets: const [target],
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Publish to GitHub (new issue)'), findsOneWidget);
      await tester.tap(find.text('Publish to GitHub (new issue)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('This creates a NEW issue.'), findsOneWidget);
      expect(find.textContaining('o/r#412'), findsWidgets);
      expect(find.text('https://github.com/o/r/issues/412'), findsOneWidget);
    });

    // The server's ALREADY_LINKED check keys on an id the drain has not written
    // yet, so nothing but this stops a second press creating a second issue.
    testWidgets('a publish already in flight cannot be pressed again', (
      tester,
    ) async {
      _tall(tester);
      final container = _container(
        _serving(
          _task(projectId: 'p-1', syncState: 'pending'),
          targets: const [target],
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Publish to GitHub'), findsNothing);
      expect(find.text('Creating the issue…'), findsOneWidget);
      expect(
        find.text('The task is saved here; the issue does not exist yet.'),
        findsOneWidget,
      );
    });

    testWidgets('the button goes dead for the whole write, not just the tap', (
      tester,
    ) async {
      _tall(tester);
      final gate = Completer<http.Response>();
      final posts = <String>[];
      final task = _task(projectId: 'p-1');
      final container = _container(
        MockClient((req) async {
          if (req.url.path == '/labels') {
            return http.Response('{"labels":[]}', 200);
          }
          if (req.url.path == '/tasks/publish-targets') {
            return http.Response(
              jsonEncode(const {
                'targets': [target],
              }),
              200,
            );
          }
          if (req.url.path == '/tasks/42/publish') {
            posts.add(req.body);
            return gate.future;
          }
          if (req.method == 'GET' && req.url.path == '/tasks') {
            return http.Response(
              jsonEncode({
                'tasks': [task],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'task': task}), 200);
        }),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Publish to GitHub'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create the issue'));
      await tester.pump();

      expect(find.text('Publishing…'), findsOneWidget);
      expect(
        tester
            .widget<AbButton>(find.widgetWithText(AbButton, 'Publishing…'))
            .onTap,
        isNull,
      );
      await tester.tap(find.text('Publishing…'), warnIfMissed: false);
      await tester.pump();
      expect(posts, hasLength(1));

      gate.complete(http.Response(jsonEncode({'task': task}), 200));
      await tester.pumpAndSettle();
    });
  });

  group('unlinking', () {
    Map<String, Object?> linked() => _task(
      projectId: 'p-1',
      source: 'github',
      externalProvider: 'github',
      externalId: 'I_1',
      externalKey: 'o/r#88',
      syncState: 'synced',
    );

    testWidgets('a linked task offers unlink and not publish', (tester) async {
      _tall(tester);
      final container = _container(
        _serving(
          linked(),
          targets: const [
            {
              'id': 'repo-1',
              'owner': 'antgrid',
              'name': 'antgrid',
              'visibility': 'public',
              'publishNewByDefault': false,
            },
          ],
        ),
      );
      await _pump(tester, container);
      await tester.pumpAndSettle();

      expect(find.text('Unlink from GitHub'), findsOneWidget);
      expect(find.textContaining('Publish to GitHub'), findsNothing);
    });

    testWidgets('the confirm separates unlinking from deleting the issue', (
      tester,
    ) async {
      _tall(tester);
      final seen = <http.Request>[];
      final container = _container(_serving(linked(), on: seen.add));
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink from GitHub'));
      await tester.pumpAndSettle();

      expect(find.text('Stop syncing ANT-42 with GitHub?'), findsOneWidget);
      expect(
        find.textContaining('Nothing happens to the issue itself'),
        findsOneWidget,
      );
      expect(find.textContaining('creates a second issue'), findsOneWidget);

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();

      final post = seen.lastWhere((r) => r.method == 'POST');
      expect(post.url.path, '/tasks/42/unlink');
      expect(jsonDecode(post.body), <String, Object?>{});
    });

    testWidgets('backing out of the unlink confirm sends nothing', (
      tester,
    ) async {
      _tall(tester);
      final seen = <http.Request>[];
      final container = _container(_serving(linked(), on: seen.add));
      await _pump(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink from GitHub'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(seen.where((r) => r.method == 'POST'), isEmpty);
    });
  });
}

class _BlockedLauncher extends TaskLauncher {
  @override
  String? unavailableReason(task) => 'workstation is offline.';

  @override
  Future<void> start(task) async {}
}
