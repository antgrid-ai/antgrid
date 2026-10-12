import 'dart:async';

import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/file_service.dart' show FileService;
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/util/external_url.dart';
import 'package:antgrid/widgets/attachment_preview_dialog.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show TransportState;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

const _pathUri = 'antgrid-path:?p=src%2Fa.ts&b=s&k=f';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);
  tearDown(() => PreviewHandoff.shared.clear());

  late LocalFakeAgentTransport transport;
  late ProjectSession session;
  late BuildContext context;
  late List<WorkspaceView> revealed;
  FileService? current;

  Future<void> pumpHost(WidgetTester tester) async {
    transport = LocalFakeAgentTransport();
    session = (await tester.runAsync(() => newFakeProjectSession(transport)))!;
    current = session.fileService;
    revealed = <WorkspaceView>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: abToastHostBuilder,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  Future<void> closeHost(WidgetTester tester) async {
    // Let any toast timer run out before the binding checks for stragglers.
    await tester.pump(const Duration(seconds: 30));
    await tester.runAsync(session.close);
  }

  Map<String, dynamic> resolveRequest() => transport.sent.lastWhere(
    (m) => m['type'] == 'file:resolve-path',
  );

  /// Pumps until [done] completes. A bare `await` on it would never return:
  /// the test body runs on a fake clock and nothing else advances it.
  Future<void> settle(
    WidgetTester tester,
    Future<void> done, {
    Duration step = const Duration(milliseconds: 50),
    int max = 40,
  }) async {
    var finished = false;
    unawaited(done.whenComplete(() => finished = true));
    for (var i = 0; i < max && !finished; i++) {
      await tester.pump(step);
    }
    expect(finished, isTrue, reason: 'link handling never finished');
    await tester.pump();
  }

  /// Delivers [reply] on the real event loop, where the transport's listeners
  /// live, so the fake clock's pump can then carry the result onward.
  Future<void> deliver(WidgetTester tester, Map<String, dynamic> reply) async {
    await tester.runAsync(() async {
      transport.emit('file:resolve-path-result', {
        'projectId': 'p',
        'requestId': resolveRequest()['requestId'],
        'isDirectory': false,
        'externalImagePath': null,
        ...reply,
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }

  Future<void> open(
    WidgetTester tester,
    String uri, {
    String? terminalId = 't1',
    Map<String, dynamic>? reply,
  }) async {
    final done = openContentLink(
      context,
      uri,
      fileService: () => session.fileService,
      previewService: () => session.previewService,
      revealView: revealed.add,
      terminalId: terminalId,
    );
    await tester.pump();
    if (reply != null) await deliver(tester, reply);
    await settle(tester, done);
  }

  testWidgets('a path link sends its path, terminal and base', (tester) async {
    await pumpHost(tester);
    await open(
      tester,
      _pathUri,
      reply: {'relPath': 'src/a.ts', 'exists': true},
    );

    final request = resolveRequest();
    expect(request['path'], 'src/a.ts');
    expect(request['terminalId'], 't1');
    expect(request['base'], 's');
    await closeHost(tester);
  });

  testWidgets('a path link with a line opens the file at that line', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(
      tester,
      'antgrid-path:?p=src%2Fa.ts&b=r&k=f&n=12&c=5',
      reply: {'relPath': 'src/a.ts', 'exists': true},
    );

    final files = session.fileService.currentState.files;
    expect(files.selectedFilePath, 'src/a.ts');
    expect(files.searchLine, 12);
    expect(revealed, [WorkspaceView.files]);
    await closeHost(tester);
  });

  testWidgets('a path link without a line clears any earlier line', (
    tester,
  ) async {
    await pumpHost(tester);
    session.fileService.selectFile('other.ts', searchLine: 7);
    await open(
      tester,
      _pathUri,
      reply: {'relPath': 'src/a.ts', 'exists': true},
    );

    final files = session.fileService.currentState.files;
    expect(files.selectedFilePath, 'src/a.ts');
    expect(files.searchLine, isNull);
    await closeHost(tester);
  });

  testWidgets('a directory result reveals the directory', (tester) async {
    await pumpHost(tester);
    await open(
      tester,
      'antgrid-path:?p=app%2Flib&b=r&k=d',
      reply: {'relPath': 'app/lib', 'isDirectory': true, 'exists': true},
    );

    expect(revealed, [WorkspaceView.files]);
    expect(
      session.fileService.currentState.expandedPaths,
      containsAll(<String>['app', 'app/lib']),
    );
    expect(session.fileService.currentState.files.selectedFilePath, isNull);
    await closeHost(tester);
  });

  testWidgets('a vanished path inside the workspace says so', (tester) async {
    await pumpHost(tester);
    await open(
      tester,
      _pathUri,
      reply: {'relPath': 'src/a.ts', 'exists': false},
    );

    expect(find.text('That path no longer exists.'), findsOneWidget);
    expect(revealed, isEmpty);
    expect(session.fileService.currentState.files.selectedFilePath, isNull);
    await closeHost(tester);
  });

  testWidgets('a timed-out check of an inside path opens it as if present', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(
      tester,
      _pathUri,
      reply: {'relPath': 'src/a.ts', 'exists': false, 'timedOut': true},
    );

    expect(session.fileService.currentState.files.selectedFilePath, 'src/a.ts');
    expect(revealed, [WorkspaceView.files]);
    expect(find.text('That path no longer exists.'), findsNothing);
    await closeHost(tester);
  });

  testWidgets('a timed-out check with no path asks to try again', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(
      tester,
      _pathUri,
      reply: {'relPath': null, 'exists': false, 'timedOut': true},
    );

    expect(
      find.text("Couldn't check that path in time. Try again."),
      findsOneWidget,
    );
    expect(find.text("Couldn't find that path."), findsNothing);
    expect(revealed, isEmpty);
    await closeHost(tester);
  });

  testWidgets('a timed-out file link with no path asks to try again', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(
      tester,
      'file:///C:/x/a.png',
      terminalId: null,
      reply: {'relPath': null, 'exists': false, 'timedOut': true},
    );

    expect(
      find.text("Couldn't check that path in time. Try again."),
      findsOneWidget,
    );
    await closeHost(tester);
  });

  group('a lookup that outlives the session it started in', () {
    const staleToasts = [
      'That path no longer exists.',
      "Couldn't find that path.",
      'That path is outside this workspace.',
    ];

    Future<void> expectDropped(
      WidgetTester tester,
      String uri, {
      String? terminalId,
      required void Function() moveOn,
      Object? Function()? focusedTarget,
      Future<void> Function()? before,
      Future<void> Function()? after,
    }) async {
      await pumpHost(tester);
      await before?.call();
      final done = openContentLink(
        context,
        uri,
        fileService: () => current,
        previewService: () => session.previewService,
        revealView: revealed.add,
        terminalId: terminalId,
        focusedTarget: focusedTarget,
      );
      await tester.pump();
      moveOn();
      await deliver(tester, {'relPath': 'src/a.ts', 'exists': true});
      await settle(tester, done);

      expect(revealed, isEmpty);
      expect(
        session.fileService.currentState.files.selectedFilePath,
        isNull,
      );
      for (final text in staleToasts) {
        expect(find.text(text), findsNothing);
      }
      await after?.call();
      await closeHost(tester);
    }

    testWidgets('is dropped when the file service was replaced', (
      tester,
    ) async {
      await expectDropped(
        tester,
        _pathUri,
        terminalId: 't1',
        moveOn: () => current = null,
      );
    });

    testWidgets('is dropped for a file link when the service was replaced', (
      tester,
    ) async {
      late ProjectSession other;
      await expectDropped(
        tester,
        'file:///C:/x/a.ts',
        moveOn: () {
          current = other.fileService;
        },
        before: () async {
          other = (await tester.runAsync(
            () => newFakeProjectSession(LocalFakeAgentTransport()),
          ))!;
        },
        after: () => tester.runAsync(other.close),
      );
    });

    testWidgets('is dropped when the focused target changed', (tester) async {
      Object? focus = 'one';
      await expectDropped(
        tester,
        _pathUri,
        terminalId: 't1',
        focusedTarget: () => focus,
        moveOn: () => focus = 'two',
      );
    });

    testWidgets('still lands when the focused target is unchanged', (
      tester,
    ) async {
      await pumpHost(tester);
      final done = openContentLink(
        context,
        _pathUri,
        fileService: () => current,
        previewService: () => session.previewService,
        revealView: revealed.add,
        terminalId: 't1',
        focusedTarget: () => 'one',
      );
      await tester.pump();
      await deliver(tester, {'relPath': 'src/a.ts', 'exists': true});
      await settle(tester, done);

      expect(revealed, [WorkspaceView.files]);
      await closeHost(tester);
    });
  });

  testWidgets('a path the bridge could not find says so', (tester) async {
    await pumpHost(tester);
    await open(tester, _pathUri, reply: {'relPath': null, 'exists': false});

    expect(find.text("Couldn't find that path."), findsOneWidget);
    expect(revealed, isEmpty);
    await closeHost(tester);
  });

  testWidgets('an existing path outside the workspace says so', (tester) async {
    await pumpHost(tester);
    await open(tester, _pathUri, reply: {'relPath': null, 'exists': true});

    expect(find.text('That path is outside this workspace.'), findsOneWidget);
    await closeHost(tester);
  });

  testWidgets('a reply from a bridge that omits exists reads as outside', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(tester, _pathUri, reply: {'relPath': null});

    expect(find.text('That path is outside this workspace.'), findsOneWidget);
    await closeHost(tester);
  });

  testWidgets('a reply from a bridge that omits exists still opens the file', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(tester, _pathUri, reply: {'relPath': 'src/a.ts'});

    expect(session.fileService.currentState.files.selectedFilePath, 'src/a.ts');
    expect(find.text('That path no longer exists.'), findsNothing);
    await closeHost(tester);
  });

  testWidgets('no reply within the wait toasts that the machine is unreachable', (
    tester,
  ) async {
    await pumpHost(tester);
    final done = openContentLink(
      context,
      _pathUri,
      fileService: () => session.fileService,
      previewService: () => session.previewService,
      revealView: revealed.add,
      terminalId: 't1',
    );
    await settle(tester, done, step: const Duration(seconds: 1), max: 12);

    expect(
      find.text("Couldn't reach the machine to open that path."),
      findsOneWidget,
    );
    await closeHost(tester);
  });

  testWidgets('a path link with no file service says so', (tester) async {
    await pumpHost(tester);
    await openContentLink(
      context,
      _pathUri,
      fileService: () => null,
      previewService: () => null,
      revealView: revealed.add,
      terminalId: 't1',
    );
    await tester.pump();

    expect(find.text("Can't open that path right now."), findsOneWidget);
    await closeHost(tester);
  });

  testWidgets('a malformed path link is reported, not guessed at', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(tester, 'antgrid-path:?p=%FF&b=r&k=f');

    expect(find.text('Could not open that link.'), findsOneWidget);
    expect(
      transport.sent.where((m) => m['type'] == 'file:resolve-path'),
      isEmpty,
    );
    await closeHost(tester);
  });

  testWidgets('a hyperlink with no scheme opens as a checkout path', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(
      tester,
      'marketing/comparisons/a.md#L3',
      reply: {'relPath': 'marketing/comparisons/a.md', 'exists': true},
    );

    final request = resolveRequest();
    expect(request['path'], 'marketing/comparisons/a.md');
    expect(request.containsKey('base'), isFalse);
    final files = session.fileService.currentState.files;
    expect(files.selectedFilePath, 'marketing/comparisons/a.md');
    expect(files.searchLine, 3);
    expect(revealed, [WorkspaceView.files]);
    await closeHost(tester);
  });

  testWidgets('without a terminal a path with no scheme is refused', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(tester, 'docs/a.md', terminalId: null);

    expect(
      find.text('Only http and https links open from the terminal.'),
      findsOneWidget,
    );
    expect(
      transport.sent.where((m) => m['type'] == 'file:resolve-path'),
      isEmpty,
    );
    await closeHost(tester);
  });

  testWidgets('without a terminal the path scheme is refused', (tester) async {
    await pumpHost(tester);
    await open(tester, _pathUri, terminalId: null);

    expect(
      find.text('Only http and https links open from the terminal.'),
      findsOneWidget,
    );
    expect(
      transport.sent.where((m) => m['type'] == 'file:resolve-path'),
      isEmpty,
    );
    await closeHost(tester);
  });

  testWidgets('without a terminal the url scheme is refused', (tester) async {
    await pumpHost(tester);
    await open(tester, 'antgrid-url:http://localhost:5173/x', terminalId: null);

    expect(
      find.text('Only http and https links open from the terminal.'),
      findsOneWidget,
    );
    expect(revealed, isEmpty);
    await closeHost(tester);
  });

  testWidgets('a detected local url goes to the preview tab', (tester) async {
    await pumpHost(tester);
    final svc = session.previewService;
    await svc.openTab(5173);
    await open(tester, 'antgrid-url:http://localhost:5173/x?y=1#z');

    expect(revealed, [WorkspaceView.preview]);
    expect(
      svc.takeNavRequest(5173),
      Uri.parse('http://localhost:5173/x?y=1#z'),
    );
    await closeHost(tester);
  });

  testWidgets('a detected non-web url inside the wrapper is refused', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(tester, 'antgrid-url:file:///etc/passwd');

    expect(
      find.text('Only http and https links open from the terminal.'),
      findsOneWidget,
    );
    expect(
      transport.sent.where((m) => m['type'] == 'file:resolve-path'),
      isEmpty,
    );
    await closeHost(tester);
  });

  testWidgets('a file link that gets the refused reply says it was not found', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(
      tester,
      'file:///C:/x/a.png',
      terminalId: null,
      reply: {'relPath': null, 'exists': false},
    );

    final request = resolveRequest();
    expect(request['path'], 'C:/x/a.png');
    expect(request.containsKey('terminalId'), isFalse);
    expect(request.containsKey('base'), isFalse);
    expect(find.text("Couldn't find that path."), findsOneWidget);
    await closeHost(tester);
  });

  testWidgets('a file link to a vanished inside path says so', (tester) async {
    await pumpHost(tester);
    await open(
      tester,
      'file:///C:/proj/a.ts',
      terminalId: null,
      reply: {'relPath': 'a.ts', 'exists': false},
    );

    expect(find.text('That path no longer exists.'), findsOneWidget);
    await closeHost(tester);
  });

  testWidgets('a file link with no file service says so', (tester) async {
    await pumpHost(tester);
    await openContentLink(
      context,
      'file:///C:/x/a.png',
      fileService: () => null,
      previewService: () => null,
      revealView: revealed.add,
    );
    await tester.pump();

    expect(find.text("Can't open that path right now."), findsOneWidget);
    await closeHost(tester);
  });

  testWidgets('a file link with no reply toasts that the machine is unreachable', (
    tester,
  ) async {
    await pumpHost(tester);
    final done = openContentLink(
      context,
      'file:///C:/x/a.png',
      fileService: () => session.fileService,
      previewService: () => session.previewService,
      revealView: revealed.add,
    );
    await settle(tester, done, step: const Duration(seconds: 1), max: 12);

    expect(
      find.text("Couldn't reach the machine to open that path."),
      findsOneWidget,
    );
    await closeHost(tester);
  });

  Future<void> dropSession(WidgetTester tester) => tester.runAsync(() async {
    transport.emitState(TransportState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  testWidgets('a path link clicked while the session is down toasts at once', (
    tester,
  ) async {
    await pumpHost(tester);
    await dropSession(tester);

    await open(tester, _pathUri);

    expect(
      find.text("Couldn't reach the machine to open that path."),
      findsOneWidget,
    );
    await closeHost(tester);
  });

  testWidgets('a file link clicked while the session is down toasts at once', (
    tester,
  ) async {
    await pumpHost(tester);
    await dropSession(tester);

    await open(tester, 'file:///C:/x/a.png', terminalId: null);

    expect(
      find.text("Couldn't reach the machine to open that path."),
      findsOneWidget,
    );
    await closeHost(tester);
  });

  testWidgets('a path link whose session drops mid-request toasts', (
    tester,
  ) async {
    await pumpHost(tester);
    final done = openContentLink(
      context,
      _pathUri,
      fileService: () => session.fileService,
      previewService: () => session.previewService,
      revealView: revealed.add,
      terminalId: 't1',
    );
    await tester.pump();
    await dropSession(tester);
    await settle(tester, done);

    expect(
      find.text("Couldn't reach the machine to open that path."),
      findsOneWidget,
    );
    await closeHost(tester);
  });

  testWidgets('a detected https url is confirmed as the inner url', (
    tester,
  ) async {
    await pumpHost(tester);
    final done = openContentLink(
      context,
      'antgrid-url:https://example.com/a?b=1#c',
      fileService: () => session.fileService,
      previewService: () => session.previewService,
      revealView: revealed.add,
      terminalId: 't1',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Open link'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('https://example.com/a?b=1#c'), findsOneWidget);
    expect(
      find.text('Only http and https links open from the terminal.'),
      findsNothing,
    );
    expect(find.textContaining('antgrid-url'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await settle(tester, done);
    expect(revealed, isEmpty);
    await closeHost(tester);
  });

  testWidgets('an image outside the workspace opens in the preview dialog', (
    tester,
  ) async {
    await pumpHost(tester);
    final done = openContentLink(
      context,
      'antgrid-path:?p=C%3A%2Fx%2Fa.png&b=a&k=i',
      fileService: () => session.fileService,
      previewService: () => session.previewService,
      revealView: revealed.add,
      terminalId: 't1',
    );
    await tester.pump();
    await deliver(tester, {
      'relPath': null,
      'externalImagePath': 'C:/x/a.png',
      'exists': true,
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
    final preview = session.fileService.currentState.preview;
    expect(preview.path, 'C:/x/a.png');
    expect(preview.displayName, 'a.png');
    expect(find.text('That path is outside this workspace.'), findsNothing);
    expect(find.text("Couldn't find that path."), findsNothing);
    expect(revealed, isEmpty);

    Navigator.of(context).pop();
    await settle(tester, done);
    await closeHost(tester);
  });
}
