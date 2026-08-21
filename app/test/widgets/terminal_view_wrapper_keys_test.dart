// The terminal's keyboard chords, pinned per platform. Two things are easy to
// break here and invisible when they are: Ghostty's Dart shim silently encodes
// NOTHING for Alt+<printable>, and an over-eager paste interception swallows the
// chord an agent CLI binds for itself (Claude Code's paste-image is ctrl+v
// everywhere except Windows/WSL, where it is alt+v).
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/clipboard_image.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/prefs_test_mock.dart';

const int _esc = 0x1B;
const int _ctrlV = 0x16;

Future<TerminalService> _makeService(
  void Function(Future<void> Function()) registerTearDown, {
  ProjectSessionMode mode = ProjectSessionMode.local,
  void Function(FakeAgentTransport transport)? onTransport,
}) async {
  final transport = FakeAgentTransport();
  onTransport?.call(transport);
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'p',
    transport: transport,
    mode: mode,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
  // Through the checkout bundle, not a bare `TerminalService.fromSession`: the
  // wrapper resolves its uploader from this terminal's own checkout, so an
  // image paste only has somewhere to go once that bundle exists.
  final bundle = session.servicesForCheckout('main');
  registerTearDown(() async {
    await bundle.dispose();
    await session.close();
  });
  return bundle.terminalService;
}

Widget _wrap(Widget child, {required SharedPreferencesWithCache prefs}) =>
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
        home: Scaffold(body: child),
      ),
    );

/// `testWidgets` with the platform override restored in a `finally`.
///
/// Resetting it on the body's last line instead leaks the override into every
/// later test the moment one expectation fails, and `addTearDown` is too late:
/// flutter_test asserts the foundation debug vars are unset while the body's
/// stack is still unwinding, before any tear-down runs.
void _platformTestWidgets(
  String description,
  TargetPlatform platform,
  WidgetTesterCallback body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps a focused terminal and returns the byte sink its engine writes to —
  /// the same external transport the real `TerminalService` attaches, so both
  /// the wrapper's interceptions and the engine's own encoding land in it.
  Future<List<int>> pumpTerminal(
    WidgetTester tester,
    String tabId, {
    String? clipboardText,
    String tabType = 'service',
    ProjectSessionMode mode = ProjectSessionMode.local,
    Future<ClipboardImage?> Function()? readImage,
    void Function(FakeAgentTransport transport)? onTransport,
  }) async {
    final written = <int>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': clipboardText ?? ''}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    useInMemoryPrefs(const {});
    final prefs = await openAppSettingsPrefs();
    final service = await _makeService(
      addTearDown,
      mode: mode,
      onTransport: onTransport,
    );
    final tab = TerminalTab(
      terminalId: tabId,
      name: tabId,
      sessionState: TerminalSessionState.running,
      type: tabType,
      cols: 80,
      rows: 24,
      driverClientId: null,
    );
    tab.ghostty.attachExternalTransport(
      writeBytes: (bytes) {
        written.addAll(bytes);
        return true;
      },
    );

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          height: 400,
          child: TerminalViewWrapper(
            tab: tab,
            terminalService: service,
            // Always injected: super_native_extensions installs a mock message
            // context under FLUTTER_TEST with no ClipboardReader handler, so a
            // real read answers neither "image" nor "no image" — it throws.
            readImage: readImage ?? () async => null,
          ),
        ),
        prefs: prefs,
      ),
    );
    await tester.pumpAndSettle();
    return written;
  }

  Future<void> chord(
    WidgetTester tester,
    List<LogicalKeyboardKey> modifiers,
    LogicalKeyboardKey key, {
    String? character,
  }) async {
    for (final m in modifiers) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.sendKeyDownEvent(key, character: character);
    await tester.sendKeyUpEvent(key);
    for (final m in modifiers.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    await tester.pumpAndSettle();
  }

  _platformTestWidgets(
    'Windows: Alt+V reaches the PTY as an ESC-prefixed chord',
    TargetPlatform.windows,
    (tester) async {
      final written = await pumpTerminal(tester, 't-alt-v');
      await chord(
        tester,
        [LogicalKeyboardKey.altLeft],
        LogicalKeyboardKey.keyV,
        character: 'v',
      );

      expect(written, [_esc, 0x76]);
    },
  );

  _platformTestWidgets(
    'Windows: AltGr (Ctrl+Alt) is not hijacked as a meta chord',
    TargetPlatform.windows,
    (tester) async {
      final written = await pumpTerminal(tester, 't-altgr');
      await chord(
        tester,
        [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft],
        LogicalKeyboardKey.keyV,
        character: 'v',
      );

      expect(written, isNot(contains(_esc)));
    },
  );

  _platformTestWidgets(
    'macOS: Option+V is left alone so it can still compose',
    TargetPlatform.macOS,
    (tester) async {
      final written = await pumpTerminal(tester, 't-option-v');
      await chord(
        tester,
        [LogicalKeyboardKey.altLeft],
        LogicalKeyboardKey.keyV,
        character: '√',
      );

      expect(written, isNot(contains(_esc)));
    },
  );

  _platformTestWidgets(
    'Linux: bare Ctrl+V reaches the PTY as ^V, not a text paste',
    TargetPlatform.linux,
    (tester) async {
      final written = await pumpTerminal(tester, 't-linux-ctrl-v');
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyV);

      expect(written, [_ctrlV]);
    },
  );

  _platformTestWidgets(
    'Linux: Ctrl+Shift+V pastes the clipboard',
    TargetPlatform.linux,
    (tester) async {
      final written = await pumpTerminal(
        tester,
        't-linux-paste',
        clipboardText: 'hi',
      );
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.keyV);

      expect(String.fromCharCodes(written), 'hi');
    },
  );

  _platformTestWidgets(
    'Windows: Ctrl+V still pastes the clipboard, and sends no ^V',
    TargetPlatform.windows,
    (tester) async {
      final written = await pumpTerminal(
        tester,
        't-win-paste',
        clipboardText: 'hi',
      );
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyV);

      expect(String.fromCharCodes(written), 'hi');
      expect(written, isNot(contains(_ctrlV)));
    },
  );
  _platformTestWidgets(
    'Ctrl+C with a running agent is swallowed, never a SIGINT',
    TargetPlatform.windows,
    (tester) async {
      final written = await pumpTerminal(tester, 't-agent-c', tabType: 'agent');
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyC);

      expect(written, isEmpty);
    },
  );

  _platformTestWidgets(
    'Ctrl+C in a plain shell still reaches the PTY as ^C',
    TargetPlatform.windows,
    (tester) async {
      final written = await pumpTerminal(tester, 't-shell-c');
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyC);

      expect(written, [0x03]);
    },
  );

  _platformTestWidgets(
    'iOS: Cmd+V pastes — an iPad keyboard has no Ctrl+V paste',
    TargetPlatform.iOS,
    (tester) async {
      final written = await pumpTerminal(
        tester,
        't-ios-paste',
        clipboardText: 'hi',
      );
      await chord(tester, [
        LogicalKeyboardKey.metaLeft,
      ], LogicalKeyboardKey.keyV);

      expect(String.fromCharCodes(written), 'hi');
    },
  );

  _platformTestWidgets(
    'iOS: Option+V composes rather than sending an ESC chord',
    TargetPlatform.iOS,
    (tester) async {
      final written = await pumpTerminal(tester, 't-ios-option-v');
      await chord(
        tester,
        [LogicalKeyboardKey.altLeft],
        LogicalKeyboardKey.keyV,
        character: '√',
      );

      expect(written, isNot(contains(_esc)));
    },
  );

  ClipboardImage anImage() => ClipboardImage(
    fileName: 'pasted.png',
    mimeType: 'image/png',
    bytes: Uint8List.fromList(const [1, 2, 3]),
  );

  _platformTestWidgets(
    'relay: an image on the clipboard is uploaded and its host path typed',
    TargetPlatform.windows,
    (tester) async {
      late FakeAgentTransport transport;
      final written = await pumpTerminal(
        tester,
        't-relay-image',
        clipboardText: 'hi',
        mode: ProjectSessionMode.relay,
        readImage: () async => anImage(),
        onTransport: (t) => transport = t,
      );
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyV);

      final start = transport.sent.firstWhere(
        (m) => m['type'] == 'file:upload-start',
      );
      expect(start['fileName'], 'pasted.png');
      expect(start['size'], 3);
      final requestId = start['requestId'] as String;

      transport.emit('file:upload-ready', {
        'requestId': requestId,
        'uploadId': 'u1',
      });
      await tester.pump();
      transport.emit('file:upload-ack', {'uploadId': 'u1', 'seq': 0});
      await tester.pump();
      transport.emit('file:upload-result', {
        'requestId': requestId,
        'uploadId': 'u1',
        'ok': true,
        'path': r'C:\proj\.antgrid\uploads\u1-pasted.png',
      });
      await tester.pump();

      final input = transport.sent.firstWhere(
        (m) => m['type'] == 'terminal:input',
      );
      expect(input['data'], r'"C:\proj\.antgrid\uploads\u1-pasted.png" ');
      // The image displaced the text paste entirely, and the chord was still
      // consumed — no `hi`, and no ^V.
      expect(written, isEmpty);
    },
  );

  _platformTestWidgets(
    'relay: a text-only clipboard still pastes text',
    TargetPlatform.windows,
    (tester) async {
      final written = await pumpTerminal(
        tester,
        't-relay-text',
        clipboardText: 'hi',
        mode: ProjectSessionMode.relay,
        readImage: () async => null,
      );
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyV);

      expect(String.fromCharCodes(written), 'hi');
      expect(written, isNot(contains(_ctrlV)));
    },
  );

  _platformTestWidgets(
    'local: an image on the clipboard is left to the agent CLI',
    TargetPlatform.windows,
    (tester) async {
      // The local agent reads the host clipboard itself and gets a native
      // attachment; intercepting would hand it a path instead.
      var probed = false;
      late FakeAgentTransport transport;
      final written = await pumpTerminal(
        tester,
        't-local-image',
        clipboardText: 'hi',
        readImage: () async {
          probed = true;
          return anImage();
        },
        onTransport: (t) => transport = t,
      );
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyV);

      expect(probed, isFalse);
      expect(String.fromCharCodes(written), 'hi');
      expect(
        transport.sent.where((m) => m['type'] == 'file:upload-start'),
        isEmpty,
      );
    },
  );

  _platformTestWidgets(
    'Linux: a composed AltGr glyph is not ESC-prefixed',
    TargetPlatform.linux,
    (tester) async {
      // X11 reports AltGr as a bare right-Alt (no Ctrl), so the Ctrl guard
      // cannot see it — the non-ASCII result is what marks it as composed.
      final written = await pumpTerminal(tester, 't-linux-altgr');
      await chord(
        tester,
        [LogicalKeyboardKey.altRight],
        LogicalKeyboardKey.keyE,
        character: '€',
      );

      expect(written, isNot(contains(_esc)));
    },
  );
}
