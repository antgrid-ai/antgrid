import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/send_to_agent_comment.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A desktop-sized window, so the box takes the centred-popover branch rather
/// than the mobile bottom sheet.
void _desktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Opens the box from a button and reports what it eventually returned.
///
/// Plain pumps, never `pumpAndSettle`: `Image.memory` decodes on the real
/// engine, off the fake test clock, so a settle after opening one with a
/// capture in it waits for a frame that never comes.
Future<String? Function()> _open(
  WidgetTester tester, {
  Uint8List? imageBytes,
  String selectedText = '<button id="submit">',
  LayerLink? anchorLink,
}) async {
  String? result;
  var returned = false;
  final trigger = Builder(
    builder: (context) => TextButton(
      onPressed: () async {
        result = await showSendToAgentComment(
          context: context,
          selectedText: selectedText,
          sourceLabel: '[from preview: http://localhost:3000/]',
          imageBytes: imageBytes,
          anchorLink: anchorLink,
        );
        returned = true;
      },
      child: const Text('open'),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: anchorLink == null
            ? trigger
            // Off in a corner, same as `SendToAgentButton`'s own fixed
            // top-right spot, so the anchored test below has somewhere
            // unambiguous to check the popover actually moved to.
            : Align(
                alignment: Alignment.topRight,
                child: CompositedTransformTarget(
                  link: anchorLink,
                  child: trigger,
                ),
              ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return () => returned ? result : null;
}

void main() {
  testWidgets('the box is centred, not pinned to a corner', (tester) async {
    _desktopWindow(tester);
    await _open(tester);

    final box = tester.getRect(find.byType(TextField));
    final screen = tester.getRect(find.byType(Scaffold));
    // Horizontally centred within a pixel, and vertically nowhere near the
    // top corner it used to be anchored into.
    expect((box.center.dx - screen.center.dx).abs(), lessThan(1));
    expect(box.center.dy, greaterThan(screen.height * 0.3));
    expect(box.center.dy, lessThan(screen.height * 0.7));
  });

  testWidgets('given an anchor, the box hangs off it instead of the centre', (
    tester,
  ) async {
    _desktopWindow(tester);
    final link = LayerLink();
    await _open(tester, anchorLink: link);

    final box = tester.getRect(find.byType(TextField));
    final screen = tester.getRect(find.byType(Scaffold));
    final button = tester.getRect(find.text('open'));
    // Nowhere near the screen's centre (where the un-anchored case lands)...
    expect((box.center.dx - screen.center.dx).abs(), greaterThan(1));
    expect(box.center.dy, lessThan(screen.height * 0.3));
    // ...and instead sits right under the button that triggered it.
    expect(box.top, greaterThanOrEqualTo(button.bottom));
    expect(box.right, lessThanOrEqualTo(button.right + 1));
  });

  testWidgets('shows the capture that is about to be attached', (tester) async {
    _desktopWindow(tester);
    // runAsync: encoding a PNG is real engine work, and a bare await inside
    // testWidgets' fake-async zone would never resolve.
    final bytes = (await tester.runAsync(() => _png(200, 120)))!;
    await _open(tester, imageBytes: bytes);

    final image = tester.widget<Image>(find.byType(Image));
    // Bounded decode, not the raw provider: a viewport capture is a
    // multi-megapixel bitmap and this draws it a couple of hundred px wide.
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    expect(resize.width, isNotNull);
    expect((resize.imageProvider as MemoryImage).bytes, bytes);
  });

  testWidgets('no image means no preview box at all', (tester) async {
    _desktopWindow(tester);
    await _open(tester);

    expect(find.byType(Image), findsNothing);
  });

  testWidgets('sending composes comment, source label and selection', (
    tester,
  ) async {
    _desktopWindow(tester);
    final read = await _open(tester);

    await tester.enterText(find.byType(TextField), 'this is misaligned');
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(
      read(),
      'this is misaligned\n'
      '[from preview: http://localhost:3000/]\n'
      '<button id="submit">',
    );
  });

  testWidgets('cancelling returns null', (tester) async {
    _desktopWindow(tester);
    final read = await _open(tester);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();

    expect(read(), isNull);
  });
}
