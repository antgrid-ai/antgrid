import 'dart:async';

import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machine = 'm1';
const _entryId = '$_machine.p1';

/// Reports [_machine]'s socket as open without dialing anything.
class _OneOpenMachine extends MachineConnectionManager {
  _OneOpenMachine() : super(crypto: CryptoService());

  @override
  List<String> openControlPlaneIds() => const [_machine];
}

SessionEntry _session(String id) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 1,
  lastUsedAt: 2,
  archived: false,
  running: false,
);

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  testWidgets(
    "a cached list from an earlier run is replaced on the machine's first advert",
    (tester) async {
      // What this device saw the last time it was connected: a session the
      // machine has since deleted.
      await stores.cachedSessionsStore.put(_entryId, [_session('gone')]);

      final transport = FakeAgentTransport();
      var listed = 0;
      transport.requestHandler = (method, params) {
        listed++;
        return {
          'sessions': [_session('current').toJson()],
        };
      };
      final client = ControlPlaneClient(transport: transport);
      addTearDown(client.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            relayConnectionManagerProvider.overrideWithValue(_OneOpenMachine()),
            controlPlaneClientForProvider(
              _machine,
            ).overrideWith((ref) async => client),
            // Nothing about the project moved during this run, so none of the
            // advert deltas fire — only the first-advert seed can refresh it.
            // Awaits the client first, as the real provider does: an advert
            // only ever arrives over a client that already exists.
            controlPlaneStateProvider(_machine).overrideWith((ref) async* {
              await ref.watch(controlPlaneClientForProvider(_machine).future);
              yield const ControlPlaneState(
                projects: [
                  AdvertisedProject(
                    projectId: 'p1',
                    running: false,
                    lastActiveAt: '2026-11-04T07:12:13.389Z',
                  ),
                ],
              );
            }),
            terminalStateProvider.overrideWith(
              (ref) => Stream.value(const TerminalState()),
            ),
            fileTreeStateProvider.overrideWith(
              (ref) => Stream.value(const FileTreeState()),
            ),
            previewStateProvider.overrideWith(
              (ref) => Stream.value(const PreviewState()),
            ),
            commandStateProvider.overrideWith(
              (ref) => Stream.value(const CommandState()),
            ),
            projectPreferencesProvider.overrideWith(
              (ref) => Stream.value(const ProjectPreferences()),
            ),
          ],
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(1200, 800)),
              child: AppShell(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(listed, 1);
      expect(
        stores.cachedSessionsStore.entries()[_entryId]?.map((s) => s.id),
        ['current'],
      );
      await stores.cachedSessionsStore.flushNow();
    },
  );
}
