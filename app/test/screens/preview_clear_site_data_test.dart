import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/preview_site_data.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/preview_screen.dart';
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/services/preview_service.dart';
import 'package:antgrid/services/preview_site_data.dart';
import 'package:antgrid/storage/preview_origin_owner_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/fake_webview_platform.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

const _kPort = 3000;

void main() {
  late RecordingWebViewPlatform platform;
  late WipeRecorder recorder;

  setUp(() {
    useInMemoryPrefs({PreviewOriginOwnerStore.key: '{}'});
    platform = installRecordingWebViewPlatform();
    recorder = WipeRecorder();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PreviewHandoff.shared.clear();
  });

  Future<({ProviderContainer container, PreviewService preview})> boot(
    WidgetTester tester, {
    bool demo = false,
  }) async {
    final session = await tester.runAsync(
      () => newFakeProjectSession(LocalFakeAgentTransport()),
    );
    addTearDown(() => tester.runAsync(session!.close));
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('p'),
        projectSessionProvider('p').overrideWith((ref) async => session!),
        previewSiteDataProvider.overrideWithValue(
          PreviewSiteData(
            store: PreviewOriginOwnerStore(),
            wipe: recorder.call,
            isDemoMode: () => false,
          ),
        ),
        if (demo) demoModeProvider.overrideWith(() => ValueController(true)),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(projectSessionProvider('p').future),
    );
    return (container: container, preview: session!.previewService);
  }

  Future<void> mount(
    WidgetTester tester,
    ProviderContainer container,
    PreviewService preview,
  ) async {
    await preview.openTab(_kPort);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: abToastHostBuilder,
          home: const Scaffold(body: PreviewScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.controllers, hasLength(1));
  }

  void desktop() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  }

  Future<void> openClearItem(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Clear site data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.text('Clear').last);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('desktop: More > Clear site data > Clear wipes, reloads and '
      'toasts', (tester) async {
    desktop();
    final rig = await boot(tester);
    await mount(tester, rig.container, rig.preview);

    await openClearItem(tester);
    expect(find.text('Clear site data?'), findsOneWidget);
    await confirm(tester);

    expect(recorder.calls, 1);
    expect(platform.controllers.single.reloads, 1);
    expect(find.text('Preview site data cleared'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancel does not wipe', (tester) async {
    desktop();
    final rig = await boot(tester);
    await mount(tester, rig.container, rig.preview);

    await openClearItem(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(recorder.calls, 0);
    expect(platform.controllers.single.reloads, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed clear toasts the failure', (tester) async {
    desktop();
    recorder.result = kOneFailureResult;
    final rig = await boot(tester);
    await mount(tester, rig.container, rig.preview);

    await openClearItem(tester);
    await confirm(tester);

    expect(recorder.calls, 1);
    expect(find.text("Couldn't clear preview site data"), findsOneWidget);
    expect(platform.controllers.single.reloads, 0);
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('demo mode refuses without a dialog', (tester) async {
    desktop();
    final rig = await boot(tester, demo: true);
    await rig.preview.openTab(_kPort);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: MaterialApp(
          builder: abToastHostBuilder,
          home: const Scaffold(body: PreviewScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await openClearItem(tester);

    expect(find.text(kDemoRefusalText), findsOneWidget);
    expect(find.text('Clear site data?'), findsNothing);
    expect(recorder.calls, 0);
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile: the panel row closes the panel and leaves the confirm '
      'dialog open', (tester) async {
    final rig = await boot(tester);
    await mount(tester, rig.container, rig.preview);

    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Refresh'), findsOneWidget);
    await tester.tap(find.text('Clear site data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Clear site data?'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);
    await confirm(tester);

    expect(recorder.calls, 1);
    expect(find.text('Refresh'), findsNothing);
    expect(find.text('Preview site data cleared'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
