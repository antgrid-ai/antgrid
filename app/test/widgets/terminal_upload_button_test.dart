import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/services/upload_service.dart';
import 'package:antgrid/widgets/terminal_upload_button.dart';

void main() {
  Widget host({
    required Future<PickedUpload?> Function() pick,
    required Future<void> Function(PickedUpload) onPicked,
    bool busy = false,
    void Function(String)? onError,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: TerminalUploadButton(
          pick: pick,
          onPicked: onPicked,
          busy: busy,
          onError: onError ?? (_) {},
        ),
      ),
    );
  }

  Finder uploadButton() => find.byType(AbIconButton);

  testWidgets('a picked file is handed to the attach pipeline', (tester) async {
    PickedUpload? handed;
    await tester.pumpWidget(
      host(
        pick: () async => PickedUpload(name: 'a.png', bytes: Uint8List(3)),
        onPicked: (p) async => handed = p,
      ),
    );
    await tester.tap(uploadButton());
    await tester.pumpAndSettle();
    expect(handed?.name, 'a.png');
  });

  testWidgets('cancelled picker is a no-op', (tester) async {
    var handed = 0;
    await tester.pumpWidget(
      host(pick: () async => null, onPicked: (_) async => handed++),
    );
    await tester.tap(uploadButton());
    await tester.pumpAndSettle();
    expect(handed, 0);
  });

  testWidgets('disables and blocks re-entry while attaching', (tester) async {
    final gate = Completer<void>();
    var picks = 0;
    await tester.pumpWidget(
      host(
        pick: () async {
          picks++;
          return PickedUpload(name: 'a.png', bytes: Uint8List(1));
        },
        onPicked: (_) => gate.future,
      ),
    );
    await tester.tap(uploadButton());
    await tester.pump();
    // Busy renders as the design-system disabled state (onTap null).
    expect(tester.widget<AbIconButton>(uploadButton()).onTap, isNull);
    await tester.tap(uploadButton());
    await tester.pump();
    expect(picks, 1); // second tap ignored
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<AbIconButton>(uploadButton()).onTap, isNotNull);
  });

  testWidgets('a paste or drop already in flight disables the button', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        pick: () async => fail('must not open the picker while busy'),
        onPicked: (_) async {},
        busy: true,
      ),
    );
    expect(tester.widget<AbIconButton>(uploadButton()).onTap, isNull);
  });

  testWidgets('an oversize pick reports via onError and never attaches', (
    tester,
  ) async {
    String? error;
    await tester.pumpWidget(
      host(
        pick: () async => throw const UploadException('TOO_LARGE', 'a.png'),
        onPicked: (_) async => fail('must not attach a rejected pick'),
        onError: (m) => error = m,
      ),
    );
    await tester.tap(uploadButton());
    await tester.pumpAndSettle();
    expect(error, contains('a.png'));
    expect(error, contains('20 MB'));
  });
}
