// Shared scaffolding for the demo-mode tests.
//
// Demo mode is deliberately reachable with no account, no keychain and no
// socket, so these helpers install ONLY the persistent-store overrides every
// widget test needs — nothing that stands in for the wire. The real
// [DemoTransport] runs in every test that reaches it, which is the point: a
// fixture that stops parsing must fail here rather than in review.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/main.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'prefs_test_mock.dart';
import 'test_store_overrides.dart';

/// A container wired like the app's root, for tests that assert on providers
/// rather than pixels.
Future<ProviderContainer> demoContainer({
  List<Override> extraOverrides = const [],
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  final container = ProviderContainer(
    overrides: [...stores.overrides, ...extraOverrides],
  );
  addTearDown(container.dispose);
  return container;
}

/// Pumps the real [AbApp] — the whole builder chain, so `DemoFrame`'s strip is
/// under test too, not just the screen below it.
///
/// [signedIn] defaults to false because that is the reviewer's case: no
/// account, straight to the sign-in screen. Pass `enterDemo: true` to skip
/// the affordance and start inside the sample project.
Future<ProviderContainer> pumpDemoApp(
  WidgetTester tester, {
  bool signedIn = false,
  bool enterDemo = false,
  Size size = const Size(400, 800),
  List<Override> extraOverrides = const [],
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        currentUserProvider.overrideWith(
          (_) async => signedIn
              ? CurrentUser(
                  userId: 'user-1',
                  email: 'dev@antgrid.local',
                  tier: 'pro',
                )
              : null,
        ),
        hasStoredSessionProvider.overrideWith((_) async => signedIn),
        // WorkspaceShell mounts WindowTitleBar directly on a desktop-sized
        // window, and the real chrome talks to the platform channel.
        windowChromeProvider.overrideWithValue(FakeWindowChrome()),
        ...extraOverrides,
      ],
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: const AbApp(),
      ),
    ),
  );
  await tester.pump();

  final container = ProviderScope.containerOf(
    tester.element(find.byType(AbApp)),
  );
  if (enterDemo) {
    enterDemoMode(container);
    await tester.pump();
    await tester.pump();
  }
  return container;
}

/// Resolves the sample project's transport the way the session factory does.
Future<AgentTransport?> demoTransportFrom(ProviderContainer container) =>
    container.read(agentTransportForProvider(kDemoProjectId).future);
