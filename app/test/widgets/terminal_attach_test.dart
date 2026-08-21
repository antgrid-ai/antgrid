// The shared attach pipeline and its desktop entry point. What breaks silently
// here: the quoted-path insert (an unquoted path splits at the first space in
// the project directory), the app-side size cap (without it a 2 GB drop starts
// a 20 MB round trip that can only end in TOO_LARGE), and the fact that a
// failure must insert NOTHING — a half-typed path into a live agent prompt is
// worse than no attach at all.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/services/upload_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/terminal_attachment_uploader.dart';
import 'package:antgrid/widgets/terminal_drop_target.dart';
import 'package:antgrid/widgets/terminal_upload_button.dart';
import 'package:antgrid/widgets/terminal_upload_strip.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _stagedPath = r'C:\proj\.antgrid\uploads\ab12cd34-a.png';

Future<String> _stagesOk({
  required String fileName,
  required Uint8List bytes,
  String? mimeType,
  void Function(int sent, int total)? onProgress,
}) async => _stagedPath;

/// An uploader wired to fakes, plus the sinks it reports through.
class _Harness {
  _Harness({UploadRunner? runner}) : runner = runner ?? _stagesOk;

  final UploadRunner runner;
  final List<String> inserted = [];
  final List<String> errors = [];
  bool serviceGone = false;

  late final TerminalAttachmentUploader uploader = TerminalAttachmentUploader(
    resolveUpload: () => serviceGone ? null : runner,
    insert: inserted.add,
    onError: errors.add,
  );
}

void main() {
  group('TerminalAttachmentUploader', () {
    test('inserts the quoted path with a trailing space on success', () async {
      final h = _Harness();
      addTearDown(h.uploader.dispose);

      await h.uploader.attach(bytes: Uint8List(4), fileName: 'a.png');

      expect(h.inserted, ['"$_stagedPath" ']);
      expect(h.errors, isEmpty);
    });

    test('rejects an oversize payload before any upload starts', () async {
      var calls = 0;
      final h = _Harness(
        runner:
            ({required fileName, required bytes, mimeType, onProgress}) async {
              calls++;
              return '/x';
            },
      );
      addTearDown(h.uploader.dispose);

      await h.uploader.attach(
        bytes: Uint8List(UploadService.kMaxUploadBytes + 1),
        fileName: 'huge.png',
      );

      expect(calls, 0);
      expect(h.inserted, isEmpty);
      expect(h.errors.single, contains('20 MB'));
      expect(h.uploader.progress.value, isNull);
    });

    test('a failed upload reports and inserts nothing', () async {
      final h = _Harness(
        runner:
            ({required fileName, required bytes, mimeType, onProgress}) async =>
                throw const UploadException('OFFLINE', ''),
      );
      addTearDown(h.uploader.dispose);

      await h.uploader.attach(bytes: Uint8List(2), fileName: 'a.png');

      expect(h.inserted, isEmpty);
      expect(h.errors.single, contains('a.png'));
      // No dead bar left over the terminal output — the snackbar says it.
      expect(h.uploader.progress.value, isNull);
    });

    test('reports OFFLINE when the checkout has no upload service', () async {
      final h = _Harness();
      addTearDown(h.uploader.dispose);
      h.serviceGone = true;

      await h.uploader.attach(bytes: Uint8List(2), fileName: 'a.png');

      expect(h.inserted, isEmpty);
      expect(h.errors.single, contains('Not connected'));
    });

    test('a second attach while one is in flight is refused as BUSY', () async {
      final gate = Completer<String>();
      final h = _Harness(
        runner: ({required fileName, required bytes, mimeType, onProgress}) =>
            gate.future,
      );
      addTearDown(h.uploader.dispose);

      final first = h.uploader.attach(bytes: Uint8List(1), fileName: 'a.png');
      await h.uploader.attach(bytes: Uint8List(1), fileName: 'b.png');
      expect(h.errors.single, contains('Too many uploads'));

      gate.complete('/staged/a.png');
      await first;
      expect(h.inserted, ['"/staged/a.png" ']);
    });

    test('progress runs staging → sending → done and then clears', () async {
      final gate = Completer<String>();
      void Function(int, int)? tick;
      final h = _Harness(
        runner: ({required fileName, required bytes, mimeType, onProgress}) {
          tick = onProgress;
          return gate.future;
        },
      );
      addTearDown(h.uploader.dispose);

      final run = h.uploader.attach(bytes: Uint8List(1), fileName: 'a.png');
      expect(h.uploader.progress.value?.phase, AttachPhase.staging);
      // Indeterminate: a round trip has no size to report against.
      expect(h.uploader.progress.value?.fraction, isNull);

      tick!(1, 4);
      expect(h.uploader.progress.value?.phase, AttachPhase.sending);
      expect(h.uploader.progress.value?.fraction, 0.25);

      gate.complete('/staged/a.png');
      await run;
      expect(h.uploader.progress.value?.phase, AttachPhase.done);

      await Future<void>.delayed(
        TerminalAttachmentUploader.kDoneHold + const Duration(milliseconds: 50),
      );
      expect(h.uploader.progress.value, isNull);
    });
  });

  group('desktop attach affordance', () {
    Future<TerminalService> makeService(ProjectSessionMode mode) async {
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p',
        transport: transport,
        mode: mode,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      final service = TerminalService.fromSession(session);
      addTearDown(() async {
        await service.dispose();
        await session.close();
      });
      return service;
    }

    Future<void> pumpWrapper(
      WidgetTester tester,
      ProjectSessionMode mode,
    ) async {
      useInMemoryPrefs(const {});
      final prefs = await openAppSettingsPrefs();
      final service = await makeService(mode);
      final tab = TerminalTab(
        terminalId: 't',
        name: 't',
        sessionState: TerminalSessionState.running,
        type: 'agent',
        cols: 80,
        rows: 24,
        driverClientId: null,
      );
      tab.ghostty.attachExternalTransport(writeBytes: (_) => true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clientIdProvider.overrideWith((ref) async => 'this-install'),
            agentTerminalProvider.overrideWith((ref) => null),
            appSettingsServiceProvider.overrideWith(
              () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: TerminalViewWrapper(tab: tab, terminalService: service),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('absent for a LOCAL session — the agent reads the same disk', (
      tester,
    ) async {
      await pumpWrapper(tester, ProjectSessionMode.local);
      expect(find.byType(TerminalAttachOverlayButton), findsNothing);
      expect(find.byType(TerminalUploadStrip), findsNothing);
    });

    testWidgets('present for a RELAY session — the files are on the wrong '
        'machine', (tester) async {
      await pumpWrapper(tester, ProjectSessionMode.relay);
      expect(find.byType(TerminalAttachOverlayButton), findsOneWidget);
      // The strip is progress only; nothing is in flight yet.
      expect(find.byType(TerminalUploadStrip), findsNothing);
    });

    // `performTerminalDrop` is a free function, so its own tests would pass
    // just as well against a tree that never mounts the drop target at all.
    // These pin the wiring itself: without them the gesture can be deleted
    // green. Both modes, because a drop displaces no native behaviour.
    testWidgets('the drop target is mounted for a LOCAL session', (
      tester,
    ) async {
      await pumpWrapper(tester, ProjectSessionMode.local);
      expect(find.byType(TerminalDropTarget), findsOneWidget);
    });

    testWidgets('the drop target is mounted for a RELAY session', (
      tester,
    ) async {
      await pumpWrapper(tester, ProjectSessionMode.relay);
      expect(find.byType(TerminalDropTarget), findsOneWidget);
    });
  });
}
