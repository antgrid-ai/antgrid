import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/upload_target.dart';
import 'package:antgrid/services/upload_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test('unfocused $platform upload uses the established transport', () async {
      debugDefaultTargetPlatformOverride = platform;
      useInMemoryPrefs();
      final cache = await CachedSessionsStore.open();
      final transport = FakeAgentTransport();
      final session = ProjectSession(
        projectId: 'p',
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: transport.dispose,
      );
      final container = ProviderContainer(
        overrides: [
          projectSessionProvider('p').overrideWith((_) async => session),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(session.close);
      await container.read(projectSessionProvider('p').future);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );

      final service = await UploadTarget(
        container,
        'p',
        'main',
      ).ready(timeout: const Duration(seconds: 1));

      expect(service, same(session.servicesForCheckout('main').uploadService));
      expect(
        WidgetsBinding.instance.lifecycleState,
        AppLifecycleState.inactive,
      );
    });
  }

  test('picker return waits for the replacement project service', () async {
    useInMemoryPrefs();
    final cache = await CachedSessionsStore.open();
    final oldTransport = FakeAgentTransport();
    final newTransport = FakeAgentTransport();
    ProjectSession session(FakeAgentTransport transport) => ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: transport.dispose,
    );
    final oldSession = session(oldTransport);
    final newSession = session(newTransport);
    var current = oldSession;
    final container = ProviderContainer(
      overrides: [
        projectSessionProvider('p').overrideWith((_) async => current),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(oldSession.close);
    addTearDown(newSession.close);
    await container.read(projectSessionProvider('p').future);
    final binding = WidgetsBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    UploadService? resolved;
    final ready = UploadTarget(container, 'p', 'main').ready().then((s) {
      resolved = s;
    });
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isNull);
    final resume = AppLifecycleListener(
      onResume: () {
        oldTransport.setEstablished(false);
        current = newSession;
        container.invalidate(projectSessionProvider('p'));
      },
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await ready;
    expect(
      resolved,
      same(newSession.servicesForCheckout('main').uploadService),
    );
    resume.dispose();
  });

  test('offline upload wait is bounded', () async {
    useInMemoryPrefs();
    final cache = await CachedSessionsStore.open();
    final transport = FakeAgentTransport()..setEstablished(false);
    final session = ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: transport.dispose,
    );
    final container = ProviderContainer(
      overrides: [
        projectSessionProvider('p').overrideWith((_) async => session),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(session.close);
    final result = expectLater(
      UploadTarget(
        container,
        'p',
        'main',
      ).ready(timeout: const Duration(milliseconds: 20)),
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'OFFLINE')),
    );
    await result;
  });
}
