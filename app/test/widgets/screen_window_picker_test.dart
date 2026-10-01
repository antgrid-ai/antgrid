import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/services/screen_share_backend.dart';
import 'package:antgrid/widgets/screen_window_picker.dart';

/// The smallest valid PNG the image decoder will accept — a 1x1 transparent
/// pixel. Thumbnails only need to be decodable here, not to look like anything.
final Uint8List _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  late StreamController<ScreenWindow> updates;

  setUp(() => updates = StreamController<ScreenWindow>.broadcast());
  tearDown(() => updates.close());

  Widget host({
    required Future<List<ScreenWindow>> Function() listWindows,
    void Function(String?)? onResult,
  }) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final id = await showScreenWindowPicker(
                context,
                listWindows: listWindows,
                windowUpdates: updates.stream,
              );
              onResult?.call(id);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  testWidgets('shows a loading state while enumerating', (tester) async {
    final gate = Completer<List<ScreenWindow>>();
    await tester.pumpWidget(host(listWindows: () => gate.future));
    await openPicker(tester);

    expect(find.byType(AbLoading), findsOneWidget);

    gate.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('lists every window with its handle', (tester) async {
    await tester.pumpWidget(
      host(
        listWindows: () async => const [
          ScreenWindow(id: '4242', title: 'Notepad'),
          ScreenWindow(id: '9001', title: 'Visual Studio Code'),
        ],
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    expect(find.byType(AbListRow), findsNWidgets(2));
    expect(find.text('Notepad'), findsOneWidget);
    expect(find.text('Visual Studio Code'), findsOneWidget);
    // The handle is the capture source id verbatim, which is what the injector
    // binds to — it belongs on screen as data, in mono.
    expect(find.text('4242'), findsOneWidget);
  });

  testWidgets('a window with no title still gets a name', (tester) async {
    await tester.pumpWidget(
      host(
        listWindows: () async => const [ScreenWindow(id: '7', title: '')],
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    expect(find.text('Untitled window'), findsOneWidget);
  });

  testWidgets('a late thumbnail replaces the placeholder in place', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        listWindows: () async => const [
          ScreenWindow(id: '4242', title: 'Notepad'),
        ],
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    // Enumeration always returns zero bytes; the image arrives later.
    expect(find.byType(Image), findsNothing);

    updates.add(
      ScreenWindow(id: '4242', title: 'Notepad', thumbnail: _onePixelPng),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Notepad'), findsOneWidget);
  });

  testWidgets('an update for an unknown window is ignored', (tester) async {
    await tester.pumpWidget(
      host(
        listWindows: () async => const [
          ScreenWindow(id: '4242', title: 'Notepad'),
        ],
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    updates.add(const ScreenWindow(id: 'stale', title: 'Gone'));
    await tester.pumpAndSettle();

    expect(find.byType(AbListRow), findsOneWidget);
    expect(find.text('Gone'), findsNothing);
  });

  testWidgets('an empty machine explains why, not a blank list', (
    tester,
  ) async {
    await tester.pumpWidget(host(listWindows: () async => const []));
    await openPicker(tester);
    await tester.pumpAndSettle();

    expect(find.byType(AbEmptyState), findsOneWidget);
    expect(find.text('No shareable windows'), findsOneWidget);
  });

  testWidgets('an enumeration failure is surfaced, not swallowed', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(listWindows: () async => throw StateError('capturer missing')),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    expect(find.text('Could not list windows'), findsOneWidget);
    expect(find.textContaining('capturer missing'), findsOneWidget);
  });

  testWidgets('picking a row resolves to its window id', (tester) async {
    String? result;
    var resolved = false;
    await tester.pumpWidget(
      host(
        listWindows: () async => const [
          ScreenWindow(id: '4242', title: 'Notepad'),
        ],
        onResult: (id) {
          result = id;
          resolved = true;
        },
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Notepad'));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(result, '4242');
  });

  testWidgets('cancelling resolves to null — no window is shared', (
    tester,
  ) async {
    String? result = 'unset';
    var resolved = false;
    await tester.pumpWidget(
      host(
        listWindows: () async => const [
          ScreenWindow(id: '4242', title: 'Notepad'),
        ],
        onResult: (id) {
          result = id;
          resolved = true;
        },
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(result, isNull);
  });

  testWidgets('refresh re-enumerates', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        listWindows: () async {
          calls++;
          return const [ScreenWindow(id: '4242', title: 'Notepad')];
        },
      ),
    );
    await openPicker(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });
}
