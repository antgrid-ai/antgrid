import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/widgets/terminal_upload_button.dart';

void main() {
  Widget host({
    required Future<PickedUpload?> Function() pick,
    required Future<String> Function(String, Uint8List) upload,
    required void Function(String) onInsertPath,
    void Function(String)? onError,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: TerminalUploadButton(
          pick: pick,
          upload: upload,
          onInsertPath: onInsertPath,
          onError: onError ?? (_) {},
        ),
      ),
    );
  }

  Finder uploadButton() => find.byType(AbIconButton);

  testWidgets('successful upload inserts the quoted path', (tester) async {
    String? inserted;
    await tester.pumpWidget(
      host(
        pick: () async => PickedUpload(name: 'a.png', bytes: Uint8List(3)),
        upload: (name, bytes) async => r'C:\proj\.antgrid\uploads\ab-a.png',
        onInsertPath: (p) => inserted = p,
      ),
    );
    await tester.tap(uploadButton());
    await tester.pumpAndSettle();
    expect(inserted, r'C:\proj\.antgrid\uploads\ab-a.png');
  });

  testWidgets('cancelled picker is a no-op', (tester) async {
    var uploads = 0;
    await tester.pumpWidget(
      host(
        pick: () async => null,
        upload: (name, bytes) async {
          uploads++;
          return '/x';
        },
        onInsertPath: (_) {},
      ),
    );
    await tester.tap(uploadButton());
    await tester.pumpAndSettle();
    expect(uploads, 0);
  });

  testWidgets('disables and blocks re-entry while uploading', (tester) async {
    final gate = Completer<String>();
    var picks = 0;
    await tester.pumpWidget(
      host(
        pick: () async {
          picks++;
          return PickedUpload(name: 'a.png', bytes: Uint8List(1));
        },
        upload: (name, bytes) => gate.future,
        onInsertPath: (_) {},
      ),
    );
    await tester.tap(uploadButton());
    await tester.pump();
    // Busy renders as the design-system disabled state (onTap null).
    expect(tester.widget<AbIconButton>(uploadButton()).onTap, isNull);
    await tester.tap(uploadButton());
    await tester.pump();
    expect(picks, 1); // second tap ignored
    gate.complete('/x');
    await tester.pumpAndSettle();
    expect(tester.widget<AbIconButton>(uploadButton()).onTap, isNotNull);
  });

  testWidgets('upload failure reports via onError', (tester) async {
    String? error;
    await tester.pumpWidget(
      host(
        pick: () async => PickedUpload(name: 'a.png', bytes: Uint8List(1)),
        upload: (name, bytes) async => throw Exception('boom'),
        onInsertPath: (_) => fail('must not insert on failure'),
        onError: (m) => error = m,
      ),
    );
    await tester.tap(uploadButton());
    await tester.pumpAndSettle();
    expect(error, isNotNull);
    expect(error, contains('a.png'));
  });
}
