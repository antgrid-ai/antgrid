import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/screen_share_backend.dart';
import 'package:antgrid/services/screen_viewer_input.dart';
import 'package:antgrid/widgets/screen_remote_input_surface.dart';

void main() {
  late List<({ViewerPointerAction action, Offset frame, String button})>
  pointers;
  late List<({Offset frame, double dx, double dy})> scrolls;
  late List<({int vk, bool down})> keys;
  late List<String> texts;

  setUp(() {
    pointers = [];
    scrolls = [];
    keys = [];
    texts = [];
  });

  /// A 500x250 viewport over a 1000x500 frame: scale 0.5, no letterbox, so every
  /// local coordinate doubles.
  Widget host({bool enabled = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 500,
          height: 250,
          child: ScreenRemoteInputSurface(
            frameSize: const ScreenFrameSize(1000, 500),
            enabled: enabled,
            onPointer: (action, frame, button) =>
                pointers.add((action: action, frame: frame, button: button)),
            onScroll: (frame, dx, dy) =>
                scrolls.add((frame: frame, dx: dx, dy: dy)),
            onKey: (vk, down) => keys.add((vk: vk, down: down)),
            onText: texts.add,
            child: const ColoredBox(
              key: ValueKey('video'),
              color: Color(0xFF000000),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('a click is translated into frame pixels', (tester) async {
    await tester.pumpWidget(host());
    // Centre of the 500x250 surface -> centre of the 1000x500 frame.
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('video'))));
    await tester.pump();

    expect(pointers.map((p) => p.action), [
      ViewerPointerAction.down,
      ViewerPointerAction.up,
    ]);
    expect(pointers.first.frame, const Offset(500, 250));
    expect(pointers.first.button, 'left');
  });

  testWidgets('a drag reports motion along the way', (tester) async {
    await tester.pumpWidget(host());
    final topLeft = tester.getTopLeft(find.byKey(const ValueKey('video')));
    await tester.dragFrom(topLeft + const Offset(10, 10), const Offset(40, 20));
    await tester.pump();

    expect(pointers.map((p) => p.action), contains(ViewerPointerAction.move));
    expect(pointers.first.frame, const Offset(20, 20));
    expect(pointers.last.frame, const Offset(100, 60));
  });

  testWidgets('a scroll is inverted into the OS wheel convention', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final centre = tester.getCenter(find.byKey(const ValueKey('video')));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(centre);
    await tester.sendEventToBinding(
      pointer.scroll(const Offset(0, kLogicalPixelsPerWheelNotch)),
    );
    await tester.pump();

    expect(scrolls, hasLength(1));
    // Flutter's positive dy scrolls content down; the injector's positive dy
    // scrolls away from the user.
    expect(scrolls.single.dy, -1.0);
    expect(scrolls.single.frame, const Offset(500, 250));
  });

  testWidgets('typing travels as text, not as a virtual key', (tester) async {
    await tester.pumpWidget(host());
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('video'))));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    expect(texts, ['a']);
    // The release must NOT be sent as a virtual key: the host never saw a press
    // for it and would release a key it is not holding.
    expect(keys, isEmpty);
  });

  testWidgets('a key with no character travels as a virtual key, both ways', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('video'))));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(keys, [(vk: 0x25, down: true), (vk: 0x25, down: false)]);
    expect(texts, isEmpty);
  });

  testWidgets('a ctrl chord travels as virtual keys so it stays a command', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('video'))));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(keys, [
      (vk: 0x11, down: true),
      (vk: 0x43, down: true),
      (vk: 0x43, down: false),
      (vk: 0x11, down: false),
    ]);
    expect(texts, isEmpty);
  });

  testWidgets('control off forwards nothing at all', (tester) async {
    await tester.pumpWidget(host(enabled: false));
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('video'))));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    expect(pointers, isEmpty);
    expect(keys, isEmpty);
    expect(texts, isEmpty);
  });

  testWidgets('a letterbox click is dropped, not clamped to the edge', (
    tester,
  ) async {
    // 500x500 over a 1000x500 frame: 125px of horizontal bar top and bottom.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              height: 500,
              child: ScreenRemoteInputSurface(
                frameSize: const ScreenFrameSize(1000, 500),
                enabled: true,
                onPointer: (action, frame, button) => pointers.add((
                  action: action,
                  frame: frame,
                  button: button,
                )),
                onScroll: (frame, dx, dy) {},
                onKey: (vk, down) {},
                onText: (_) {},
                child: const ColoredBox(
                  key: ValueKey('video'),
                  color: Color(0xFF000000),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final topLeft = tester.getTopLeft(find.byKey(const ValueKey('video')));
    await tester.tapAt(topLeft + const Offset(250, 10));
    await tester.pump();

    expect(pointers, isEmpty);
  });
}
