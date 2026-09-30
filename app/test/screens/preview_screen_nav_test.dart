// webview_all re-exports only the creation params; the platform classes a
// recording fake has to extend live in the transitive interface package.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/screens/preview_screen.dart';
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/services/preview_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';
import '../helpers/fake_agent_transport.dart';

// PreviewService queues a followed link's load and hands it to whichever
// PreviewScreen builds the tab's webview next; these tests pin the screen's
// half of that handover against a platform fake that records every load, so a
// screen that stopped calling takeNavRequest fails on what the webview was
// actually asked to load.

class _RecordingPlatform extends WebViewPlatform {
  final controllers = <_RecordingController>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _RecordingController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _QuietNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _BlankWebViewWidget(params);
}

class _RecordingController extends PlatformWebViewController {
  _RecordingController(super.params) : super.implementation();

  final loads = <Uri>[];

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loads.add(params.uri);

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

class _QuietNavigationDelegate extends PlatformNavigationDelegate {
  _QuietNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnSSlAuthError(
    SslAuthErrorCallback onSslAuthError,
  ) async {}
}

class _BlankWebViewWidget extends PlatformWebViewWidget {
  _BlankWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

extension on _RecordingController {
  Iterable<String> get loadedUrls => loads.map((u) => u.toString());
}

class _LocalFakeTransport extends FakeAgentTransport {
  @override
  bool get isLocal => true;
}

const _kPort = 3000;
const _kOtherPort = 4000;
const _kOrigin = 'http://localhost:3000';
const _kLink = '/dashboard?x=1#h';

void main() {
  late WebViewPlatform? originalPlatform;
  late _RecordingPlatform platform;

  setUp(() {
    originalPlatform = WebViewPlatform.instance;
    platform = _RecordingPlatform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() {
    PreviewHandoff.shared.clear();
    // The interface's setter rejects null, so a run that started with no
    // platform installed leaves the fake behind rather than restoring it.
    if (originalPlatform != null) WebViewPlatform.instance = originalPlatform;
  });

  Future<({ProviderContainer container, PreviewService preview})> boot(
    WidgetTester tester,
  ) async {
    final session = await tester.runAsync(() async {
      final cache = await CachedSessionsStore.open();
      final transport = _LocalFakeTransport();
      return ProjectSession(
        projectId: 'p',
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
    });
    addTearDown(() => tester.runAsync(session!.close));
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('p'),
        projectSessionProvider('p').overrideWith((ref) async => session!),
      ],
    );
    addTearDown(container.dispose);
    // The screen resolves the service with a synchronous read of the resolved
    // session, so it has to be resolved before anything mounts.
    await tester.runAsync(
      () => container.read(projectSessionProvider('p').future),
    );
    return (container: container, preview: session!.previewService);
  }

  Widget host(ProviderContainer container, {required bool showPreview}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: showPreview ? const PreviewScreen() : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Future<void> openLocalTab(PreviewService preview, int port) async {
    await preview.openTab(port);
    expect(preview.currentState.tabs.map((t) => t.port), contains(port));
  }

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
        await tester.pump();

        expect(platform.controllers, hasLength(1));
        expect(platform.controllers.single.loadedUrls, [
          '$_kOrigin$_kLink',
        ]);

        // A later emission for the same tab set must neither rebuild the
        // controller nor replay the link.
        await openLocalTab(rig.preview, _kOtherPort);
        await tester.pump();
        rig.preview.setActiveTab(_kPort);
        await tester.pump();

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
        await tester.pump();
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
        await openLocalTab(rig.preview, _kOtherPort);
        await tester.pump();
        rig.preview.setActiveTab(_kPort);
        await tester.pump();
        expect(platform.controllers, hasLength(2));
        expect(first.loadedUrls, [_kOrigin, '$_kOrigin$_kLink']);

        await tester.pumpWidget(host(rig.container, showPreview: false));
        await tester.pump();
        await tester.pumpWidget(host(rig.container, showPreview: true));
        await tester.pump();

        expect(platform.controllers, hasLength(4));
        expect(
          platform.controllers.skip(2).map((c) => c.loadedUrls.toList()),
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
      await tester.pump();
      final controller = platform.controllers.single;
      expect(controller.loadedUrls, [_kOrigin]);

      await rig.preview.openTab(_kPort, path: _kLink);
      await tester.pump();
      await tester.pump();

      expect(platform.controllers, hasLength(1));
      expect(controller.loadedUrls, [_kOrigin]);

      // The reopen above emits nothing on the already-active tab, so force
      // real rebuilds: a queued load would surface on either of them.
      await openLocalTab(rig.preview, _kOtherPort);
      await tester.pump();
      rig.preview.setActiveTab(_kPort);
      await tester.pump();

      expect(platform.controllers, hasLength(2));
      expect(controller.loadedUrls, [_kOrigin]);
    });
  });
}
