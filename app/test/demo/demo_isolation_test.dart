// The demo's one hard promise is that nothing it shows or does outlives it:
// no cached sessions, no persisted layout, no status file, no telemetry. Each
// of those is a separate store with its own write path, so each gets its own
// assertion here — a single missed guard is a sample project the user finds
// sitting in their drawer after a relaunch.
import 'package:antgrid/analytics/analytics_service.dart';
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/fixtures/demo_workspace_fixtures.dart';
import 'package:antgrid/main.dart' show telemetryAllowed;
import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/focused_tools.dart';
import 'package:antgrid/providers/analytics.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/drawer_collapsed_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:antgrid/storage/recent_ports_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/demo_harness.dart';
import '../helpers/prefs_test_mock.dart';

SessionEntry _entry(String id) => SessionEntry(
  id: id,
  name: 'sample',
  createdAt: 1,
  lastUsedAt: 2,
  archived: false,
  running: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the session cache', () {
    test('refuses the demo on all three write paths', () async {
      useInMemoryPrefs();
      final store = await CachedSessionsStore.open();
      addTearDown(store.close);

      await store.put(kDemoProjectId, [_entry('s1')]);
      store.putLabel(kDemoProjectId, kDemoDisplayName);
      store.putStatus(kDemoProjectId, 'working');

      expect(store.has(kDemoProjectId), isFalse);
      expect(store.get(kDemoProjectId), isEmpty);
      expect(store.label(kDemoProjectId), isNull);
      expect(store.statusOf(kDemoProjectId), isNull);
      expect(store.entries(), isEmpty);
    });

    test('still accepts a real project', () async {
      useInMemoryPrefs();
      final store = await CachedSessionsStore.open();
      addTearDown(store.close);

      await store.put('real-project', [_entry('s1')]);
      store.putLabel('real-project', 'real');

      expect(store.has('real-project'), isTrue);
      expect(store.label('real-project'), 'real');
    });
  });

  group('the Recent list', () {
    // The cache guards above are all WRITE-side: they keep the demo out of the
    // store. Nothing stopped the demo READING it back, and Recent is the one
    // demo surface that renders the whole store rather than the focused
    // project — so a tester with real history saw their own machines listed
    // under a banner promising nothing was connected.
    test('drops the real machines the cache is full of', () async {
      final container = await demoContainer();
      final store = container.read(cachedSessionsStoreProvider);
      await store.put('real-project', [_entry('s1')]);

      // The same read is the user's real Recent list, so the gate below has to
      // be the demo flag and not an empty fixture.
      expect(
        container.read(recentSessionsProvider).map((r) => r.origin.projectId),
        contains('real-project'),
      );

      enterDemoMode(container);

      expect(container.read(recentSessionsProvider), isEmpty);
    });

    // The demo's own rows come from the LIVE session state, never the cache,
    // so nothing in the store can name their project. Without the sample
    // project standing in as the local match, every row falls through to
    // `buildRecentSessions`' unmatched-key branch and wears the raw id.
    testWidgets('names the sample project rather than its raw id', (
      tester,
    ) async {
      final container = await pumpDemoApp(tester, enterDemo: true);
      await tester.pump(const Duration(milliseconds: 100));

      final rows = container.read(recentSessionsProvider);
      expect(rows, isNotEmpty);
      expect(rows.map((r) => r.origin.projectName).toSet(), {kDemoDisplayName});
    });
  });

  group('recent ports', () {
    test('the demo dev server is never remembered', () async {
      useInMemoryPrefs();
      final store = await RecentPortsStore.open();
      addTearDown(store.close);

      await store.add(kDemoProjectId, 5173, 'http');

      expect(store.list(kDemoProjectId), isEmpty);
    });

    test('a real project still remembers its ports', () async {
      useInMemoryPrefs();
      final store = await RecentPortsStore.open();
      addTearDown(store.close);

      await store.add('real-project', 5173, 'http');

      expect(store.list('real-project'), hasLength(1));
    });
  });

  test('project preferences resolve to defaults, off disk', () async {
    final container = await demoContainer();
    enterDemoMode(container);

    // PreferencesService keys one file by projectId — the demo must never be
    // the id that file is written under. Read through a live subscription:
    // `container.read(...future)` closes its own subscription before the
    // stream's first microtask, so it never settles.
    final sub = container.listen(
      projectPreferencesProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    final prefs = sub.read().value;
    expect(prefs, isNotNull);
    // Defaults, not a file: every field is what the constructor gives.
    expect(prefs!.splitRatio, const ProjectPreferences().splitRatio);
    expect(prefs.selectedFilePath, isNull);
    expect(prefs.expandedPaths, isEmpty);
    expect(prefs.panelMode, isNull);
  });

  test('the eviction snapshot writes no status file for the demo', () async {
    final container = await demoContainer();
    enterDemoMode(container);
    // Warm the session so `snapshotAndInvalidateOnEvict` has something to
    // snapshot; without it the write is skipped for an uninteresting reason.
    final session = await container.read(
      projectSessionProvider(kDemoProjectId).future,
    );
    expect(session, isA<ProjectSession>());

    final cache = container.read(projectStatusCacheProvider);
    await container
        .read(projectSessionRegistryProvider.notifier)
        .forceEvictAndSettle(kDemoProjectId);

    expect(await cache.read(kDemoProjectId), isNull);
  });

  test('the session carries no analytics sink', () async {
    final container = await demoContainer(
      extraOverrides: [
        analyticsServiceProvider.overrideWithValue(_RecordingAnalytics()),
      ],
    );
    enterDemoMode(container);

    final demo = await container.read(
      projectSessionProvider(kDemoProjectId).future,
    );

    expect(demo.analytics, isNull);
  });

  test('telemetry is off while the demo is on, whatever the setting', () async {
    final container = await demoContainer();
    // The default, and the case that matters: an opted-in user who opens the
    // sample project must still send nothing about it.
    expect(container.read(appSettingsServiceProvider).telemetryEnabled, isTrue);
    expect(telemetryAllowed(container), isTrue);

    enterDemoMode(container);
    expect(telemetryAllowed(container), isFalse);

    exitDemoMode(container);
    expect(telemetryAllowed(container), isTrue);
  });

  test('the drawer is the sample project and nothing else', () async {
    final container = await demoContainer();
    enterDemoMode(container);
    await container.read(projectSessionProvider(kDemoProjectId).future);

    // Not merely "the demo appears": the demo must be the WHOLE list. Every
    // other source the merge reads costs a keychain read or a relay dial, and
    // an empty list here is what made the drawer header say "PROJECTS · 0"
    // over a workspace that was plainly showing one.
    expect(container.read(drawerEntriesProvider).map((e) => e.id), <String>[
      kDemoProjectId,
    ]);
  });

  test('the demo is not in the drawer once it is left', () async {
    final container = await demoContainer();
    enterDemoMode(container);
    exitDemoMode(container);

    expect(
      container.read(drawerEntriesProvider).map((e) => e.id),
      isNot(contains(kDemoProjectId)),
    );
  });

  test('the file tree writes nothing into the last real project', () async {
    final container = await demoContainer();
    // The state that makes this dangerous: PreferencesService is still pointed
    // at a REAL project, because nothing rebinds it for the demo. A binding
    // made here would debounce-write the sample project's expanded paths and
    // selection into that project's preferences.json — and the binding's own
    // `projectId == null` guard would not catch it, since the id is non-null
    // and simply belongs to someone else.
    final prefsService = container.read(preferencesServiceProvider);
    await prefsService.load('real-project');
    expect(prefsService.projectId, 'real-project');

    final written = <ProjectPreferences>[];
    final prefsSub = prefsService.stream.listen(written.add);
    addTearDown(prefsSub.cancel);

    enterDemoMode(container);
    final session = await container.read(
      projectSessionProvider(kDemoProjectId).future,
    );
    // The binding is anchored in fileTreeStateProvider, so it is the act of
    // watching the tree that would create it.
    final treeSub = container.listen(
      fileTreeStateProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(treeSub.close);
    await Future<void>.delayed(Duration.zero);

    // Exactly what a reviewer poking around the sample project does, and the
    // only thing that makes the write observable: an untouched tree emits a
    // state equal to the defaults, which `update` drops on its own.
    session.fileService
      ..toggleExpanded('src')
      ..selectFile(kDemoFileContents.keys.first);
    await Future<void>.delayed(Duration.zero);

    expect(written, isEmpty);
    expect(prefsService.current, const ProjectPreferences());
  });

  test('the New Session picker offers only the sample project', () async {
    final container = await demoContainer();
    enterDemoMode(container);

    final sources = container.read(pickerSourcesProvider);
    expect(sources.map((s) => s.id), <String>['local']);
    expect(sources.single.projects.map((p) => p.id), <String>[kDemoProjectId]);
  });

  test('the drawer and the picker name the sample project the same', () async {
    final container = await demoContainer();
    enterDemoMode(container);

    // Two surfaces, two independent sources; a demo that named itself
    // differently in each would read as two projects.
    expect(
      container.read(drawerEntriesProvider).single.displayName,
      container.read(pickerSourcesProvider).single.projects.single.name,
    );
  });

  test('the project list refuses the demo', () async {
    useInMemoryPrefs();
    final store = await ProjectStore.open();

    // What opening the sample project's drawer row does: activation records an
    // open, and an open is an upsert.
    await store.upsert(demoProject());

    expect(store.list(), isEmpty);
  });

  test('the collapsed-drawer set keeps real ids and drops the demo', () async {
    useInMemoryPrefs();
    final store = await DrawerCollapsedStore.open();

    // One tap on the sample project's row is enough to put its id in here, and
    // nothing prunes the set afterwards.
    await store.write(<String>{'real-project', kDemoProjectId});

    expect(store.read(), <String>{'real-project'});
  });

  test('the branch catalog answers from fixtures, never from a host', () async {
    final container = await demoContainer();
    enterDemoMode(container);

    // The New Session canvas resolves branches for whatever the picker has
    // selected. Without the demo gate the local arm calls
    // `HostController.ensureHost()`, which SPAWNS the real bridge.
    container
        .read(selectedTargetProjectProvider.notifier)
        .set(container.read(pickerSourcesProvider).single.projects.single);

    final catalog = await container.read(
      newSessionBranchCatalogProvider.future,
    );

    expect(catalog?.branches, kDemoBranches);
    expect(catalog?.current, kDemoBranch);
  });

  test('a paused flush holds the user\u0027s own queued events', () async {
    final posted = <String>[];
    var demo = false;
    final service = AnalyticsService(
      client: MockClient((req) async {
        posted.add(req.url.path);
        return http.Response('', 202);
      }),
      plausibleUrl: 'https://plausible.test',
      plausibleDomain: 'antgrid.test',
      eventsApiUrl: 'https://events.test',
      installId: 'install-1',
      platform: 'test',
      appVersion: '0.0.0',
      // Composed exactly as main() composes it, so the demo really does stop
      // `track` from enqueuing.
      enabled: () => !demo,
      paused: () => demo,
    );

    service.track('real_event');
    demo = true;
    // The pause-lifecycle flush the demo's own entry fires.
    await service.flush();
    expect(posted.where((p) => p.endsWith('/events')), isEmpty);

    demo = false;
    await service.flush();
    expect(posted.where((p) => p.endsWith('/events')), hasLength(1));
  });

  test('nothing the demo opens asks for the bridge host', () async {
    // Value-blind on purpose. Every provider below swallows a host failure and
    // answers with the same empty/null it answers with under its demo gate, so
    // the returned value cannot tell a guard from a spawn — only whether the
    // controller was ever read can. That makes this the one assertion that
    // still fails if someone deletes a gate.
    var askedForHost = false;
    final container = await demoContainer(
      extraOverrides: [
        hostControllerProvider.overrideWith((ref) {
          askedForHost = true;
          throw StateError('the demo reached HostController');
        }),
      ],
    );
    enterDemoMode(container);
    // The workspace half needs nothing else — `enterDemoMode` focuses the
    // sample project, and a LocalProject is what sends every one of these down
    // their local arm. The New Session half needs a draft target, which the
    // user supplies by picking the sample project in the composer.
    final project = container
        .read(pickerSourcesProvider)
        .single
        .projects
        .single;
    container.read(selectedTargetProjectProvider.notifier).set(project);

    await container.read(focusedMachineToolsProvider.future);
    await container.read(newSessionDetectedToolsProvider.future);
    await container.read(newSessionChatCapableToolsProvider.future);
    await container.read(newSessionBranchCatalogProvider.future);
    await container.read(
      newSessionBranchRemoteStatusProvider((
        targetId: project.id,
        branch: kDemoBranch,
      )).future,
    );

    expect(askedForHost, isFalse);
  });
}

/// Fails the test if the demo ever reaches a sink. Deliberately not a spy with
/// assertions after the fact: a track() here is already the bug.
class _RecordingAnalytics implements AnalyticsService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    fail('the demo reached AnalyticsService.${invocation.memberName}');
  }
}
