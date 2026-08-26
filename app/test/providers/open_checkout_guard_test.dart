import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/open_checkout.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/storage/project_store.dart';

import '../helpers/prefs_test_mock.dart';

/// `openCheckoutIn` / `copyCheckoutPath` resolve their path over the LOOPBACK
/// control plane, and reaching it SPAWNS the local bridge host. Their doc says
/// callers must not offer them for a relay-backed project; these pin that the
/// functions enforce it themselves, so a menu that stops gating (or a new
/// caller) cannot ask this machine about another machine's checkout.
void main() {
  const localUuid = 'local-device-uuid';
  const localProjectId = '6e5c50e5d6f973a8';
  const remoteProjectId = 'uuidA.6e5c50e5d6f973a8';

  late int hostReads;
  late int clipboardWrites;

  /// Pumps a tree and hands back a context plus its container.
  Future<(BuildContext, ProviderContainer)> pumpHarness(
    WidgetTester tester,
  ) async {
    useInMemoryPrefs();
    final projectStore = await ProjectStore.open();
    await projectStore.upsert(
      AbProject(
        projectId: localProjectId,
        folder: '/repos/antgrid',
        displayName: 'antgrid',
        hostDeviceUuid: localUuid,
        hostMachineName: 'desk',
        lastOpenedAt: DateTime.now(),
      ),
    );

    hostReads = 0;
    clipboardWrites = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboardWrites++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectStoreProvider.overrideWithValue(projectStore),
          localDeviceUuidProvider.overrideWith((_) async => localUuid),
          // Counts the reach rather than serving one: the host client is a live
          // loopback socket, and what these tests are about is whether it is
          // reached at all.
          hostControlClientProvider.overrideWith((_) async {
            hostReads++;
            throw StateError('no host in tests');
          }),
        ],
        child: MaterialApp(
          home: Scaffold(body: Builder(builder: (_) => const SizedBox())),
        ),
      ),
    );
    final context = tester.element(find.byType(SizedBox));
    return (context, ProviderScope.containerOf(context));
  }

  testWidgets('a remote project never reaches the local host', (tester) async {
    final (context, container) = await pumpHarness(tester);

    await copyCheckoutPath(
      context,
      container,
      projectId: remoteProjectId,
      checkoutId: 'main',
    );
    await tester.pump();

    expect(hostReads, 0);
    expect(clipboardWrites, 0);
  });

  testWidgets('a project hosted by another device never reaches the host', (
    tester,
  ) async {
    final (context, container) = await pumpHarness(tester);
    await container
        .read(projectsProvider.notifier)
        .upsert(
          AbProject(
            projectId: 'a1b2c3d4e5f60718',
            folder: '/repos/other',
            displayName: 'other',
            hostDeviceUuid: 'some-other-device',
            hostMachineName: 'build-server',
            lastOpenedAt: DateTime.now(),
          ),
        );

    await copyCheckoutPath(
      context,
      container,
      projectId: 'a1b2c3d4e5f60718',
      checkoutId: 'main',
    );
    await tester.pump();

    expect(hostReads, 0);
    expect(clipboardWrites, 0);
  });

  testWidgets('a local project still reaches the host', (tester) async {
    final (context, container) = await pumpHarness(tester);

    await copyCheckoutPath(
      context,
      container,
      projectId: localProjectId,
      checkoutId: 'main',
    );
    await tester.pump();

    // The guard is a gate, not a wall: the local path is unchanged, and the
    // unreachable host in this harness surfaces as the usual snackbar.
    expect(hostReads, 1);
    expect(find.text('Could not reach the local host.'), findsOneWidget);
  });
}
