import 'dart:async';

import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/navigation/back_intent.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/preview_site_data.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/screens/preview_screen.dart';
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/services/preview_service.dart';
import 'package:antgrid/services/preview_site_data.dart';
import 'package:antgrid/storage/preview_origin_owner_store.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;

import '../helpers/carbon_guard.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/fake_webview_platform.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

// The Preview screen sits under a single AbCarbonScope; every state it can
// show, and every menu it opens, must leave no Ab* widget inside that scope.

const _kPort = 3000;

final _focus = NotifierProvider<ValueController<String?>, String?>(
  () => ValueController<String?>('p'),
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
  description: 'CarbonButton "$label"',
);

void main() {
  late RecordingWebViewPlatform platform;

  setUp(() {
    useInMemoryPrefs({PreviewOriginOwnerStore.key: '{}'});
    platform = installRecordingWebViewPlatform();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PreviewHandoff.shared.clear();
  });

  void usePlatform(TargetPlatform p) => debugDefaultTargetPlatformOverride = p;

  // The binding checks its debug overrides before any tearDown runs, so the
  // platform has to be put back inside the test body.
  void testWidgets(String description, Future<void> Function(WidgetTester) body) =>
      ft.testWidgets(description, (tester) async {
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Widget app(
    Widget home, {
    Brightness brightness = Brightness.dark,
    double textScale = 1,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: abToastHostBuilder(context, child),
    ),
    home: Scaffold(body: home),
  );

  Future<ProviderContainer> loadedRig(
    WidgetTester tester, {
    Completer<void>? gate,
  }) async {
    final recorder = WipeRecorder()..gate = gate;
    final session = await tester.runAsync(
      () => newFakeProjectSession(LocalFakeAgentTransport()),
    );
    addTearDown(() => tester.runAsync(session!.close));
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWith(
          (ref) => ref.watch(_focus),
        ),
        projectSessionProvider('p').overrideWith((ref) async => session!),
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
    await tester.runAsync(() => container.read(projectSessionProvider('p').future));
    final PreviewService preview = session!.previewService;
    await preview.openTab(_kPort);
    return container;
  }

  Future<void> mountLoaded(
    WidgetTester tester,
    ProviderContainer container, {
    Brightness brightness = Brightness.dark,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: app(
          const PreviewScreen(),
          brightness: brightness,
          textScale: textScale,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> mountStream(
    WidgetTester tester,
    Stream<PreviewState> stream, {
    Brightness brightness = Brightness.dark,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        // A failed provider otherwise retries and stays "loading".
        retry: (_, _) => null,
        overrides: [previewStateProvider.overrideWith((ref) => stream)],
        child: app(const PreviewScreen(), brightness: brightness),
      ),
    );
  }

  void expectGuardEmpty(WidgetTester tester) {
    expect(abWidgetsInScope(tester), isEmpty);
  }

  Future<void> pumpMenu(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final platformName in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      final tag = '${platformName.name}/${brightness.name}';

      testWidgets('loaded view has no Ab widget ($tag)', (tester) async {
        usePlatform(platformName);
        final container = await loadedRig(tester);
        await mountLoaded(tester, container, brightness: brightness);

        expect(platform.controllers, hasLength(1));
        expectGuardEmpty(tester);
      });

      testWidgets('empty view has no Ab widget ($tag)', (tester) async {
        usePlatform(platformName);
        await mountStream(
          tester,
          Stream.value(const PreviewState()),
          brightness: brightness,
        );
        await tester.pump();

        expect(find.text('Open a preview'), findsOneWidget);
        expectGuardEmpty(tester);
      });

      testWidgets('error view has no Ab widget ($tag)', (tester) async {
        usePlatform(platformName);
        await mountStream(
          tester,
          Stream<PreviewState>.error(Exception('boom')),
          brightness: brightness,
        );
        await tester.pump();
        await tester.pump();

        expect(find.text("Couldn't load the preview"), findsOneWidget);
        expectGuardEmpty(tester);
      });

      testWidgets('loading view has no Ab widget ($tag)', (tester) async {
        usePlatform(platformName);
        await mountStream(
          tester,
          const Stream<PreviewState>.empty(),
          brightness: brightness,
        );

        expect(find.byType(CarbonLoading), findsOneWidget);
        expectGuardEmpty(tester);
      });
    }
  }

  testWidgets('the open ports list has no Ab widget', (tester) async {
    usePlatform(TargetPlatform.windows);
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);

    await tester.tap(_button('Open ports'));
    await pumpMenu(tester);

    expect(find.text('Open a port…'), findsOneWidget);
    expectGuardEmpty(tester);
  });

  testWidgets('the desktop overflow menu has no Ab widget', (tester) async {
    usePlatform(TargetPlatform.windows);
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);

    await tester.tap(_button('More'));
    await pumpMenu(tester);

    expect(find.text('Clear site data'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);
    expectGuardEmpty(tester);
  });

  testWidgets('the phone overflow menu has no Ab widget', (tester) async {
    usePlatform(TargetPlatform.android);
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);

    await tester.tap(_button('More'));
    await pumpMenu(tester);

    expect(find.text('Draw on the page'), findsOneWidget);
    expect(find.text('Close this tab'), findsOneWidget);
    expect(find.text('Open a port…'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);
    expectGuardEmpty(tester);
  });

  testWidgets('the phone toolbar has Reload and no Forward', (tester) async {
    usePlatform(TargetPlatform.android);
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);

    expect(_button('Refresh'), findsOneWidget);
    expect(_button('Forward'), findsNothing);
  });

  for (final open in ['Open ports', 'More']) {
    testWidgets('back with "$open" open closes only the popup', (tester) async {
      usePlatform(TargetPlatform.android);
      final container = await loadedRig(tester);
      container
          .read(visibleWorkspaceViewProvider.notifier)
          .set(WorkspaceView.preview);
      await mountLoaded(tester, container);

      await tester.tap(_button(open));
      await pumpMenu(tester);
      expect(
        find.text(open == 'More' ? 'Close this tab' : 'Open a port…'),
        findsOneWidget,
      );

      // A system back reaches both the app's back scope and the popup's own
      // route pop entry, in that order: the scope must swallow it while the
      // menu is open, and the route entry closes the menu.
      expect(resolveBackIntent(container), isTrue);
      if (open == 'More') await tester.binding.handlePopRoute();
      await pumpMenu(tester);

      expect(
        find.text(open == 'More' ? 'Close this tab' : 'Open a port…'),
        findsNothing,
      );
      expect(
        container.read(previewStateProvider).value?.tabs.length,
        1,
        reason: 'the active tab must stay open',
      );
    });
  }

  testWidgets('the right-click menu has no Ab widget', (tester) async {
    usePlatform(TargetPlatform.windows);
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);

    final at = tester.getCenter(find.byKey(const ValueKey('preview-$_kPort')));
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(at);
    await mouse.up();
    // No page answers the fake's script, so the menu comes from the timer.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Select all'), findsOneWidget);
    expectGuardEmpty(tester);

    // The platform view swallows pointers, so the next click over the page
    // has to close the menu itself.
    final primary = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await primary.down(at - const Offset(120, 0));
    await primary.up();
    await pumpMenu(tester);
    expect(find.text('Select all'), findsNothing);
  });

  testWidgets('ports button badge and name track the open ports', (
    tester,
  ) async {
    usePlatform(TargetPlatform.windows);
    final handle = tester.ensureSemantics();
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);

    expect(find.bySemanticsLabel('Open ports, 1'), findsOneWidget);
    handle.dispose();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('phone toolbar fits 320 px at text scale $scale', (
      tester,
    ) async {
      usePlatform(TargetPlatform.android);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = await loadedRig(tester);
      await mountLoaded(tester, container, textScale: scale);

      expect(tester.takeException(), isNull);
      for (final label in ['Back', 'Refresh', 'Open ports', 'More']) {
        final size = tester.getSize(_button(label));
        expect(size.width, greaterThanOrEqualTo(44), reason: label);
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
      }
      final bar = tester.getRect(find.byType(CarbonLayerSurface).first);
      expect(bar.width, lessThanOrEqualTo(320));
    });
  }

  testWidgets('the progress bar stays still until the view is on screen', (
    tester,
  ) async {
    usePlatform(TargetPlatform.windows);
    // An unknown owner map makes admission wipe first, which the gate holds.
    useInMemoryPrefs();
    final gate = Completer<void>();
    final container = await loadedRig(tester, gate: gate);
    await mountLoaded(tester, container);

    final bar = find.byType(CarbonProgressBar);
    expect(bar, findsOneWidget);
    TickerMode ticker() => tester.widget<TickerMode>(
      find.ancestor(of: bar, matching: find.byType(TickerMode)).first,
    );
    expect(ticker().enabled, isFalse);

    container
        .read(visibleWorkspaceViewProvider.notifier)
        .set(WorkspaceView.preview);
    await tester.pump();
    expect(ticker().enabled, isTrue);

    container.read(visibleWorkspaceViewProvider.notifier).set(null);
    gate.complete();
    await tester.pump();
    await tester.pump();
  });

  testWidgets('switching tabs does not rebuild the webview', (tester) async {
    usePlatform(TargetPlatform.windows);
    final container = await loadedRig(tester);
    await mountLoaded(tester, container);
    final preview = container
        .read(projectSessionProvider('p'))
        .requireValue
        .previewService;
    await preview.openTab(4000);
    await tester.pump();
    await tester.pump();
    final tabView = find.byKey(
      const ValueKey('preview-$_kPort'),
      skipOffstage: false,
    );
    final before = tester.element(tabView);

    preview.setActiveTab(_kPort);
    await tester.pump();
    await tester.pump();

    // Same element: the platform view was kept, not disposed and recreated.
    expect(tester.element(tabView), same(before));
    expect(platform.controllers, hasLength(2));
  });
}
