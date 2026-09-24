// The create form is the confirm step for publishing, so the rules that decide
// whether a switch is on when the user presses Create are the whole safety
// property: a private note must never become a public issue because a control
// moved underneath already-typed text.
import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/models/task.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/util/detached.dart';
import 'package:antgrid/widgets/tasks/task_create_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _taskJson = {
  'number': 7,
  'title': 'Fix the drawer',
  'body': '',
  'status': 'open',
  'sortKey': 'm',
  'source': 'local',
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
};

Map<String, Object?> _target({
  String id = 'repo-1',
  String owner = 'antgrid',
  String name = 'antgrid',
  String visibility = 'public',
  bool byDefault = false,
}) => {
  'id': id,
  'owner': owner,
  'name': name,
  'visibility': visibility,
  'publishNewByDefault': byDefault,
};

/// Serves the whole task surface, and records the create body so the test can
/// assert what actually went out rather than what the form looked like.
MockClient _serving(
  List<Map<String, Object?>> targets, {
  void Function(http.Request)? on,
}) {
  return MockClient((req) async {
    on?.call(req);
    if (req.url.path == '/labels') return http.Response('{"labels":[]}', 200);
    if (req.url.path == '/tasks/publish-targets') {
      return http.Response(jsonEncode({'targets': targets}), 200);
    }
    if (req.method == 'GET' && req.url.path == '/tasks') {
      return http.Response('{"tasks":[]}', 200);
    }
    return http.Response(jsonEncode({'task': _taskJson}), 200);
  });
}

ProviderContainer _container(
  MockClient client, {
  String? projectId = 'p-1',
  Map<String, String> projectNames = const {},
  List<UnlinkedRepo> unlinked = const [],
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
      taskAssigneeCandidatesProvider.overrideWithValue(const []),
      taskProjectNamesProvider.overrideWithValue(projectNames),
      taskUnlinkedReposProvider.overrideWith((ref) async => unlinked),
    ],
  );
  addTearDown(container.dispose);
  if (projectId != null) {
    container.read(taskFilterProvider.notifier).setProject(projectId);
  }
  return container;
}

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => GestureDetector(
              onTap: () => detached(
                'test',
                'open create sheet',
                () => showTaskCreateSheet(ctx),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

AbSwitch _publishSwitch(WidgetTester tester) =>
    tester.widget<AbSwitch>(find.byType(AbSwitch));

Future<void> _create(WidgetTester tester) async {
  await tester.enterText(find.byType(EditableText).first, 'Fix the drawer');
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('Create task'));
  await tester.pumpAndSettle();
}

Map<String, Object?> _createBody(List<http.Request> seen) {
  final post = seen.lastWhere(
    (r) => r.method == 'POST' && r.url.path == '/tasks',
  );
  return jsonDecode(post.body) as Map<String, Object?>;
}

void main() {
  testWidgets('with no project there is nothing to publish to, and no switch', (
    tester,
  ) async {
    final seen = <http.Request>[];
    final container = _container(
      _serving([_target()], on: seen.add),
      projectId: null,
    );
    await _open(tester, container);

    expect(find.text('Create on GitHub too'), findsNothing);
    expect(find.byType(AbSwitch), findsNothing);
    await _create(tester);
    // Still stated on the wire — the field is required, and absent means the
    // server refuses rather than guessing.
    expect(_createBody(seen)['publish'], isFalse);
  });

  testWidgets('a project with no enabled repo offers no switch either', (
    tester,
  ) async {
    final container = _container(_serving(const []));
    await _open(tester, container);

    expect(find.text('Create on GitHub too'), findsNothing);
  });

  testWidgets('one repo is preselected and named, and starts off', (
    tester,
  ) async {
    final seen = <http.Request>[];
    final container = _container(_serving([_target()], on: seen.add));
    await _open(tester, container);

    expect(find.text('Create on GitHub too'), findsOneWidget);
    expect(find.text('antgrid/antgrid'), findsOneWidget);
    expect(_publishSwitch(tester).value, isFalse);
    expect(find.text('Stays in this Antgrid account.'), findsOneWidget);

    await _create(tester);
    final body = _createBody(seen);
    expect(body['publish'], isFalse);
    expect(body.containsKey('publishRepoId'), isFalse);
  });

  testWidgets(
    'the repo default positions the switch, and says it is a setting',
    (tester) async {
      final seen = <http.Request>[];
      final container = _container(
        _serving([_target(byDefault: true)], on: seen.add),
      );
      await _open(tester, container);

      expect(_publishSwitch(tester).value, isTrue);
      expect(
        find.textContaining('On by default for antgrid/antgrid'),
        findsOneWidget,
      );
      // The ON state carries the weight: the destination and its visibility are
      // both on screen beside the switch.
      expect(find.text('Will be created in'), findsOneWidget);
      expect(
        find.textContaining(
          'This repo is public, so the issue will be public.',
        ),
        findsOneWidget,
      );

      await _create(tester);
      final body = _createBody(seen);
      expect(body['publish'], isTrue);
      expect(body['publishRepoId'], 'repo-1');
      expect(body['projectId'], 'p-1');
    },
  );

  testWidgets('turning the default off publishes nothing', (tester) async {
    final seen = <http.Request>[];
    final container = _container(
      _serving([_target(byDefault: true)], on: seen.add),
    );
    await _open(tester, container);

    await tester.tap(find.byType(AbSwitch));
    await tester.pumpAndSettle();
    expect(_publishSwitch(tester).value, isFalse);

    await _create(tester);
    expect(_createBody(seen)['publish'], isFalse);
  });

  testWidgets('several repos means an explicit choice, with no default', (
    tester,
  ) async {
    final container = _container(
      _serving([
        _target(byDefault: true),
        _target(id: 'repo-2', name: 'site', visibility: 'private'),
      ]),
    );
    await _open(tester, container);

    // A default belonging to one of several repos must not position a switch
    // that has no destination yet.
    expect(_publishSwitch(tester).value, isFalse);
    expect(_publishSwitch(tester).onChanged, isNull);
    expect(
      find.textContaining('Pick one before turning this on.'),
      findsOneWidget,
    );
  });

  testWidgets('the switch arms only after a repo is chosen', (tester) async {
    final seen = <http.Request>[];
    final container = _container(
      _serving([
        _target(),
        _target(id: 'repo-2', name: 'site', visibility: 'private'),
      ], on: seen.add),
    );
    await _open(tester, container);

    await tester.tap(find.text('Choose a repo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('antgrid/site'));
    await tester.pumpAndSettle();

    // Choosing a destination is not consent to use it.
    expect(_publishSwitch(tester).value, isFalse);
    expect(_publishSwitch(tester).onChanged, isNotNull);
    await tester.tap(find.byType(AbSwitch));
    await tester.pumpAndSettle();
    expect(_publishSwitch(tester).value, isTrue);
    expect(
      find.textContaining('visible to whoever can see the repo'),
      findsOneWidget,
    );

    await _create(tester);
    final body = _createBody(seen);
    expect(body['publish'], isTrue);
    expect(body['publishRepoId'], 'repo-2');
  });

  testWidgets('filing a half-written note against a project cannot arm it', (
    tester,
  ) async {
    final container = _container(
      _serving([_target(byDefault: true)]),
      projectId: null,
      projectNames: const {'p-1': 'Antgrid'},
    );
    await _open(tester, container);

    // The customer name typed into a private note, before any project exists
    // to publish it to.
    await tester.enterText(find.byType(EditableText).at(1), 'Acme is churning');
    await tester.pumpAndSettle();
    await tester.tap(find.text('No project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Antgrid'));
    await tester.pumpAndSettle();

    expect(find.text('Create on GitHub too'), findsOneWidget);
    expect(_publishSwitch(tester).value, isFalse);
  });

  testWidgets('choosing a project before typing still honours the default', (
    tester,
  ) async {
    final container = _container(
      _serving([_target(byDefault: true)]),
      projectId: null,
      projectNames: const {'p-1': 'Antgrid'},
    );
    await _open(tester, container);

    await tester.tap(find.text('No project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Antgrid'));
    await tester.pumpAndSettle();

    expect(_publishSwitch(tester).value, isTrue);
  });

  group('the Create button', () {
    AbButton createButton(WidgetTester tester) => tester.widget<AbButton>(
      find.ancestor(
        of: find.textContaining('Create task'),
        matching: find.byType(AbButton),
      ),
    );

    testWidgets('is disabled while nothing is filled in', (tester) async {
      final container = _container(_serving(const []));
      await _open(tester, container);

      expect(createButton(tester).onTap, isNull);
    });

    testWidgets(
      'enables once there is a title, and disables again if cleared',
      (tester) async {
        final container = _container(_serving(const []));
        await _open(tester, container);

        await tester.enterText(find.byType(EditableText).first, 'Fix it');
        await tester.pump();
        expect(createButton(tester).onTap, isNotNull);

        await tester.enterText(find.byType(EditableText).first, '');
        await tester.pump();
        expect(createButton(tester).onTap, isNull);
      },
    );

    testWidgets('a whitespace-only title does not count', (tester) async {
      final container = _container(_serving(const []));
      await _open(tester, container);

      await tester.enterText(find.byType(EditableText).first, '    ');
      await tester.pump();
      expect(createButton(tester).onTap, isNull);
    });

    testWidgets(
      'a description alone is not enough — the title is what is required',
      (tester) async {
        final container = _container(_serving(const []));
        await _open(tester, container);

        await tester.enterText(find.byType(EditableText).last, 'Only a body');
        await tester.pump();
        expect(createButton(tester).onTap, isNull);
      },
    );
  });

  group('repos the GitHub App can see but no machine has opened', () {
    const repo = UnlinkedRepo(
      id: 'r-7',
      repoKey: 'github.com/acme/angular-main',
    );

    MockClient serving(List<http.Request> seen, {int fromRepoStatus = 200}) {
      return MockClient((req) async {
        seen.add(req);
        if (req.url.path == '/account/projects/from-repo') {
          if (fromRepoStatus != 200) {
            return http.Response('{"error":"REPO_NOT_FOUND"}', fromRepoStatus);
          }
          return http.Response(
            jsonEncode({
              'project': {
                'id': 'p-9',
                'repoKey': 'github.com/acme/angular-main',
                'displayName': 'angular-main',
              },
            }),
            200,
          );
        }
        if (req.url.path == '/account/projects') {
          return http.Response('{"projects":[]}', 200);
        }
        if (req.url.path == '/labels') {
          return http.Response('{"labels":[]}', 200);
        }
        if (req.url.path == '/tasks/publish-targets') {
          return http.Response('{"targets":[]}', 200);
        }
        if (req.method == 'GET' && req.url.path == '/tasks') {
          return http.Response('{"tasks":[]}', 200);
        }
        return http.Response(jsonEncode({'task': _taskJson}), 200);
      });
    }

    testWidgets(
      'the picker lists them, and choosing one files the task there',
      (tester) async {
        final seen = <http.Request>[];
        final container = _container(
          serving(seen),
          projectNames: const {'p-1': 'antgrid'},
          unlinked: const [repo],
        );
        await _open(tester, container);

        await tester.tap(find.text('antgrid'));
        await tester.pumpAndSettle();
        expect(find.text('angular-main'), findsOneWidget);
        expect(
          find.text('GitHub repo, not opened on a machine yet'),
          findsOneWidget,
        );

        await tester.tap(find.text('angular-main'));
        await tester.pumpAndSettle();

        // The project was made from THIS repo, by its id — never a name.
        final made = seen.singleWhere(
          (r) => r.url.path == '/account/projects/from-repo',
        );
        expect(jsonDecode(made.body), {'repoId': 'r-7'});

        await _create(tester);
        expect(_createBody(seen)['projectId'], 'p-9');
      },
    );

    testWidgets('a failure keeps the earlier project and says so', (
      tester,
    ) async {
      final seen = <http.Request>[];
      final container = _container(
        serving(seen, fromRepoStatus: 404),
        projectNames: const {'p-1': 'antgrid'},
        unlinked: const [repo],
      );
      await _open(tester, container);

      await tester.tap(find.text('antgrid'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('angular-main'));
      await tester.pumpAndSettle();

      await _create(tester);
      // Still filed where it was, not against a project that was never made.
      expect(_createBody(seen)['projectId'], 'p-1');
    });

    testWidgets('with only unlinked repos the picker is still offered', (
      tester,
    ) async {
      final container = _container(
        serving(<http.Request>[]),
        projectId: null,
        unlinked: const [repo],
      );
      await _open(tester, container);

      expect(find.text('No project'), findsOneWidget);
      await tester.tap(find.text('No project'));
      await tester.pumpAndSettle();
      expect(find.text('angular-main'), findsOneWidget);
    });
  });
}
