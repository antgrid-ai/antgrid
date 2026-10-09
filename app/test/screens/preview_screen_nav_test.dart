import 'dart:async';

import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_progress_rule.dart';
import 'package:antgrid/design/widgets/ab_url_field.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/preview_site_data.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/preview_screen.dart';
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/services/preview_service.dart';
import 'package:antgrid/services/preview_site_data.dart';
import 'package:antgrid/storage/preview_origin_owner_store.dart';
import 'package:antgrid/widgets/preview_draw_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_all/webview_all.dart'
    show JavaScriptMessage, UrlChange;
import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/fake_webview_platform.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

// PreviewService queues a followed link's load and hands it to whichever
// PreviewScreen builds the tab's webview next; these tests pin the screen's
// half of that handover against a platform fake that records every load, so a
// screen that stopped calling takeNavRequest fails on what the webview was
// actually asked to load. They also pin that no tab loads before its port's
// website data has been attributed to the right owner.

const _kPort = 3000;
const _kOtherPort = 4000;
const _kOrigin = 'http://localhost:3000';
const _kLink = '/dashboard?x=1#h';

// Which project the screen is focused on.
final _focus = NotifierProvider<ValueController<String?>, String?>(
  () => ValueController<String?>('p'),
);

void main() {
  late RecordingWebViewPlatform platform;
  late WipeRecorder recorder;
  late List<int> controllersAtWipe;
  late List<List<int>> retiredAtWipe;

  setUp(() {
    // A known, empty owner map: first admissions record without clearing.
    useInMemoryPrefs({PreviewOriginOwnerStore.key: '{}'});
    platform = installRecordingWebViewPlatform();
    controllersAtWipe = [];
    retiredAtWipe = [];
    recorder = WipeRecorder()
      ..onCall = () {
        controllersAtWipe.add(platform.controllers.length);
        retiredAtWipe.add([for (final c in platform.controllers) c.retirements]);
      };
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PreviewHandoff.shared.clear();
  });

  Future<
    ({ProviderContainer container, PreviewService preview, PreviewService other})
  >
  boot(WidgetTester tester) async {
    final session = await tester.runAsync(
      () => newFakeProjectSession(LocalFakeAgentTransport()),
    );
    final otherSession = await tester.runAsync(
      () => newFakeProjectSession(LocalFakeAgentTransport(), projectId: 'q'),
    );
    addTearDown(() => tester.runAsync(session!.close));
    addTearDown(() => tester.runAsync(otherSession!.close));
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWith(
          (ref) => ref.watch(_focus),
        ),
        projectSessionProvider('p').overrideWith((ref) async => session!),
        projectSessionProvider('q').overrideWith((ref) async => otherSession!),
        previewSiteDataProvider.overrideWithValue(
          PreviewSiteData(
            store: PreviewOriginOwnerStore(),
            wipe: recorder.call,
            isDemoMode: () => false,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // The screen resolves the service with a synchronous read of the resolved
    // session, so it has to be resolved before anything mounts.
    await tester.runAsync(() async {
      await container.read(projectSessionProvider('p').future);
      await container.read(projectSessionProvider('q').future);
    });
    return (
      container: container,
      preview: session!.previewService,
      other: otherSession!.previewService,
    );
  }

  Widget host(ProviderContainer container, {required bool showPreview}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: abToastHostBuilder,
        home: Scaffold(
          body: showPreview ? const PreviewScreen() : const SizedBox.shrink(),
        ),
      ),
    );
  }

  // Admission resolves on the microtask queue after the build that started
  // it, so a controller exists one frame later.
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump();
  }

  Future<void> openLocalTab(PreviewService preview, int port) async {
    await preview.openTab(port);
    expect(preview.currentState.tabs.map((t) => t.port), contains(port));
  }

  // Opens a second tab and refocuses the first: two emissions that rebuild the
  // screen for real, where setActiveTab on the already-active tab emits
  // nothing.
  Future<void> forceRebuilds(WidgetTester tester, PreviewService preview) async {
    await openLocalTab(preview, _kOtherPort);
    await settle(tester);
    preview.setActiveTab(_kPort);
    await settle(tester);
  }

  Future<Map<int, String>?> storedOwners(WidgetTester tester) async =>
      await tester.runAsync<Map<int, String>?>(PreviewOriginOwnerStore().read);

  AbIconButton toolbarButton(WidgetTester tester, String tooltip) =>
      tester.widget<AbIconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(AbIconButton),
        ),
      );

  String addressText(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byType(AbUrlField),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  group('PreviewScreen followed-link consumption', () {
    testWidgets(
      'a link queued before the screen mounts is the fresh controller\'s '
      'first and only load',
      (tester) async {
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);
        await rig.preview.openTab(
          _kPort,
          path: _kLink,
          navigateExisting: true,
        );

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);

        expect(platform.controllers, hasLength(1));
        expect(platform.controllers.single.loadedUrls, [
          '$_kOrigin$_kLink',
        ]);

        // A later emission for the same tab set must neither rebuild the
        // controller nor replay the link.
        await forceRebuilds(tester, rig.preview);

        expect(platform.controllers, hasLength(2));
        expect(platform.controllers.first.loadedUrls, ['$_kOrigin$_kLink']);
        expect(platform.controllers.last.loadedUrls, [
          'http://localhost:$_kOtherPort',
        ]);
      },
    );

    testWidgets(
      'a link followed while mounted is one extra load on the same '
      'controller, and a remount does not replay it',
      (tester) async {
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);
        expect(platform.controllers, hasLength(1));
        final first = platform.controllers.single;
        expect(first.loadedUrls, [_kOrigin]);

        await rig.preview.openTab(
          _kPort,
          path: _kLink,
          navigateExisting: true,
        );
        await tester.pump();
        await tester.pump();

        expect(platform.controllers, hasLength(1));
        expect(first.loadedUrls, [_kOrigin, '$_kOrigin$_kLink']);

        // One consumed request stays consumed: neither an unrelated emission
        // nor a remount may load it again. setActiveTab on the tab that is
        // already active emits nothing, so a second tab is what makes the
        // follow-up rebuilds real.
        await forceRebuilds(tester, rig.preview);
        expect(platform.controllers, hasLength(2));
        expect(first.loadedUrls, [_kOrigin, '$_kOrigin$_kLink']);

        await tester.pumpWidget(host(rig.container, showPreview: false));
        await tester.pump();
        // Unmounting retires both pages and never clears: the owner is the
        // same one that recorded these ports.
        expect(platform.controllers.map((c) => c.retirements), [1, 1]);
        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);

        expect(recorder.calls, 0);
        expect(platform.controllers, hasLength(4));
        expect(
          platform.controllers.skip(2).map((c) => c.loadedUrls),
          [
            [_kOrigin],
            ['http://localhost:$_kOtherPort'],
          ],
        );
        expect(first.loadedUrls, [_kOrigin, '$_kOrigin$_kLink']);
      },
    );

    testWidgets('navigateExisting false on an open tab loads nothing', (
      tester,
    ) async {
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      final controller = platform.controllers.single;
      expect(controller.loadedUrls, [_kOrigin]);

      await rig.preview.openTab(_kPort, path: _kLink);
      await tester.pump();
      await tester.pump();

      expect(platform.controllers, hasLength(1));
      expect(controller.loadedUrls, [_kOrigin]);

      // The reopen above emits nothing on the already-active tab, so force
      // real rebuilds: a queued load would surface on either of them.
      await forceRebuilds(tester, rig.preview);

      expect(platform.controllers, hasLength(2));
      expect(controller.loadedUrls, [_kOrigin]);
    });
  });

  group('PreviewScreen website data ownership', () {
    testWidgets('no controller exists until admission resolves', (
      tester,
    ) async {
      useInMemoryPrefs();
      final gate = recorder.gate = Completer<void>();
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);

      expect(platform.controllers, isEmpty);
      expect(find.byType(AbProgressRule), findsOneWidget);

      gate.complete();
      await settle(tester);

      expect(platform.controllers, hasLength(1));
      expect(platform.controllers.single.loadedUrls, [_kOrigin]);
      expect(controllersAtWipe, [0]);
      expect(find.textContaining('Preview site data'), findsNothing);
    });

    testWidgets(
      'a project switch onto the same URL retires the old page and wipes '
      'before the new controller loads',
      (tester) async {
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);
        await openLocalTab(rig.other, _kPort);

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);
        expect(platform.controllers, hasLength(1));
        expect(recorder.calls, 0);

        // The clear must wait for the dropped page to be blanked.
        final retireGate = platform.controllers.single.retireGate =
            Completer<void>();
        rig.container.read(_focus.notifier).set('q');
        await settle(tester);
        await settle(tester);
        expect(platform.controllers.single.retirements, 1);
        expect(recorder.calls, 0);
        expect(platform.controllers, hasLength(1));

        retireGate.complete();
        await settle(tester);
        await settle(tester);

        expect(platform.controllers, hasLength(2));
        expect(controllersAtWipe, [1]);
        expect(retiredAtWipe, [
          [1],
        ]);
        expect(platform.controllers.last.loadedUrls, [_kOrigin]);
        expect(platform.controllers.first.reloads, 0);
        expect(await storedOwners(tester), {_kPort: 'q'});
        expect(
          find.text(
            'Preview site data cleared: port 3000 was last used by another '
            'project',
          ),
          findsOneWidget,
        );

        // Local mode: two projects sharing one physical port clear on every
        // focus switch.
        rig.container.read(_focus.notifier).set('p');
        await settle(tester);
        await settle(tester);
        expect(recorder.calls, 2);
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets('a link followed while admission is pending is the only '
        'first load', (tester) async {
      useInMemoryPrefs();
      final gate = recorder.gate = Completer<void>();
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      expect(platform.controllers, isEmpty);

      await rig.preview.openTab(_kPort, path: _kLink, navigateExisting: true);
      await settle(tester);
      expect(platform.controllers, isEmpty);

      gate.complete();
      await settle(tester);

      expect(platform.controllers, hasLength(1));
      expect(platform.controllers.single.loadedUrls, ['$_kOrigin$_kLink']);
    });

    for (final (label, input) in [
      ('a port link', 'localhost:3000/login'),
      ('a path', '/login'),
    ]) {
      testWidgets('an address-bar submit of $label while pending is the first '
          'load', (tester) async {
        useInMemoryPrefs();
        final gate = recorder.gate = Completer<void>();
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);
        expect(platform.controllers, isEmpty);

        await tester.enterText(
          find.descendant(
            of: find.byType(AbUrlField),
            matching: find.byType(EditableText),
          ),
          input,
        );
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await settle(tester);
        expect(platform.controllers, isEmpty);

        gate.complete();
        await settle(tester);

        expect(recorder.calls, 1);
        expect(platform.controllers, hasLength(1));
        expect(platform.controllers.single.loadedUrls, ['$_kOrigin/login']);
      });
    }

    testWidgets('a tab closed while pending builds nothing', (tester) async {
      useInMemoryPrefs();
      final gate = recorder.gate = Completer<void>();
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);

      await rig.preview.closeTab(_kPort);
      await settle(tester);
      gate.complete();
      await settle(tester);

      expect(recorder.calls, 1);
      expect(platform.controllers, isEmpty);
    });

    testWidgets(
      'an owner switch while pending never builds the new owner\'s page early',
      (tester) async {
        useInMemoryPrefs();
        final gate = recorder.gate = Completer<void>();
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);
        await openLocalTab(rig.other, _kPort);

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);

        rig.container.read(_focus.notifier).set('q');
        await settle(tester);
        expect(platform.controllers, isEmpty);

        gate.complete();
        await settle(tester);
        await settle(tester);

        expect(recorder.calls, 2);
        expect(controllersAtWipe, [0, 0]);
        expect(platform.controllers, hasLength(1));
        expect(platform.controllers.single.loadedUrls, [_kOrigin]);
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets(
      'an owner switch during another batch\'s wipe still clears before the '
      'new owner loads',
      (tester) async {
        useInMemoryPrefs({PreviewOriginOwnerStore.key: '{"4000":"x"}'});
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);
        await openLocalTab(rig.other, _kPort);

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);
        expect(platform.controllers, hasLength(1));
        expect(recorder.calls, 0);

        final gate = recorder.gate = Completer<void>();
        await openLocalTab(rig.preview, _kOtherPort);
        await settle(tester);
        expect(recorder.calls, 1);

        rig.container.read(_focus.notifier).set('q');
        await settle(tester);

        gate.complete();
        await settle(tester);
        await settle(tester);

        expect(recorder.calls, 2);
        // p's pending 4000 tab left the screen with the focus switch, so only
        // q's port is live to keep.
        expect(await storedOwners(tester), {_kPort: 'q'});
        expect(platform.controllers.map((c) => c.loadedUrls), [
          [_kOrigin],
          [_kOrigin],
        ]);
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets('a wipe reloads every live tab once and disarms draw', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      useInMemoryPrefs({PreviewOriginOwnerStore.key: '{"4000":"x"}'});
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      final first = platform.controllers.single;

      await tester.tap(find.byTooltip('Draw on the page'));
      await tester.pump();
      expect(find.byType(PreviewDrawOverlay), findsOneWidget);

      // Opened in the background so the armed tab stays on screen: only the
      // wipe can take the overlay away.
      await rig.preview.openTab(_kOtherPort, focus: false);
      await settle(tester);
      await settle(tester);

      expect(rig.preview.currentState.activeTabId, _kPort);
      expect(recorder.calls, 1);
      expect(platform.controllers, hasLength(2));
      expect(first.reloads, 1);
      expect(platform.controllers.last.reloads, 0);
      expect(find.byType(PreviewDrawOverlay), findsNothing);
      expect(toolbarButton(tester, 'Draw on the page').selected, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a failed wipe still loads the tab', (tester) async {
      useInMemoryPrefs({PreviewOriginOwnerStore.key: '{"3000":"x"}'});
      recorder.throwing = StateError('boom');
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      await settle(tester);

      expect(recorder.calls, 1);
      expect(platform.controllers, hasLength(1));
      expect(platform.controllers.single.loadedUrls, [_kOrigin]);
      expect(await storedOwners(tester), {_kPort: ''});
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets(
      'a tab closed during another batch\'s wipe leaves its port unsettled',
      (tester) async {
        useInMemoryPrefs({PreviewOriginOwnerStore.key: '{"4000":"x"}'});
        const closedPort = 5000;
        final rig = await boot(tester);
        await openLocalTab(rig.preview, _kPort);
        await openLocalTab(rig.preview, closedPort);
        await openLocalTab(rig.other, closedPort);

        await tester.pumpWidget(host(rig.container, showPreview: true));
        await settle(tester);
        expect(platform.controllers, hasLength(2));
        expect(recorder.calls, 0);

        final gate = recorder.gate = Completer<void>();
        await openLocalTab(rig.preview, _kOtherPort);
        await settle(tester);
        expect(recorder.calls, 1);

        // Its page ran while the clear was in flight, so what it wrote may
        // have survived the clear.
        await rig.preview.closeTab(closedPort);
        await settle(tester);
        gate.complete();
        await settle(tester);
        await settle(tester);

        expect(await storedOwners(tester), {
          _kPort: 'p',
          _kOtherPort: 'p',
          closedPort: PreviewOriginOwnerStore.unsettled,
        });

        rig.container.read(_focus.notifier).set('q');
        await settle(tester);
        await settle(tester);
        expect(recorder.calls, 2);
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets('a retired page\'s callbacks never reach its successor', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);
      await openLocalTab(rig.other, _kPort);
      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      final retired = platform.controllers.single;
      rig.container.read(_focus.notifier).set('q');
      await settle(tester);
      await settle(tester);
      expect(platform.controllers, hasLength(2));
      final live = platform.controllers.last;

      await tester.tap(find.byTooltip('Pick an element'));
      await tester.pump();
      expect(toolbarButton(tester, 'Pick an element').selected, isTrue);
      final address = addressText(tester);

      retired.delegate!.onUrlChange!(
        const UrlChange(url: 'http://localhost:3000/stale'),
      );
      retired.delegate!.onPageFinished!('http://localhost:3000/stale');
      retired.channels['AntgridElementPicker']!(
        const JavaScriptMessage(message: '{"type":"cancelled"}'),
      );
      await tester.pump();

      expect(addressText(tester), address);
      expect(toolbarButton(tester, 'Pick an element').selected, isTrue);

      // The same deliveries from the live page do land.
      live.channels['AntgridElementPicker']!(
        const JavaScriptMessage(message: '{"type":"cancelled"}'),
      );
      await tester.pump();
      expect(toolbarButton(tester, 'Pick an element').selected, isFalse);
      live.delegate!.onUrlChange!(
        const UrlChange(url: 'http://localhost:3000/fresh'),
      );
      await tester.pump();
      expect(addressText(tester), 'http://localhost:3000/fresh');

      await tester.pump(const Duration(seconds: 10));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a retired page\'s history never lands on its successor', (
      tester,
    ) async {
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);
      await openLocalTab(rig.other, _kPort);
      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      final retired = platform.controllers.single;

      // Its history query is still out when the project switch drops it.
      final history = retired.historyGate = Completer<bool>();
      retired.delegate!.onPageFinished!(_kOrigin);
      rig.container.read(_focus.notifier).set('q');
      await settle(tester);
      await settle(tester);
      expect(platform.controllers, hasLength(2));

      history.complete(true);
      await settle(tester);
      expect(toolbarButton(tester, 'Back').onTap, isNull);

      // The live page's own history does enable Back.
      final live = platform.controllers.last;
      live.historyGate = Completer<bool>()..complete(true);
      live.delegate!.onPageFinished!(_kOrigin);
      await settle(tester);
      expect(toolbarButton(tester, 'Back').onTap, isNotNull);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('closing a live tab retires its page', (tester) async {
      final rig = await boot(tester);
      await openLocalTab(rig.preview, _kPort);

      await tester.pumpWidget(host(rig.container, showPreview: true));
      await settle(tester);
      final controller = platform.controllers.single;
      expect(controller.retirements, 0);

      await rig.preview.closeTab(_kPort);
      await settle(tester);

      expect(controller.retirements, 1);
    });
  });
}
