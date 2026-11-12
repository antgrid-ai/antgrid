import 'package:carbon_flutter_gallery/gallery_app.dart';
import 'package:carbon_flutter_gallery/registry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  expect(finder, findsOneWidget, reason: key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  expect(tester.takeException(), isNull, reason: 'after $key');
}

Future<void> _openSettings(WidgetTester tester) async {
  if (find.byKey(const ValueKey('settings-toggle')).evaluate().isNotEmpty) {
    await _tap(tester, 'settings-toggle');
  }
}

void main() {
  void useSize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  testWidgets('every page survives every setting at 320 width', (tester) async {
    useSize(tester, const Size(320, 800));
    await tester.pumpWidget(const GalleryApp());
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _openSettings(tester);

    for (final entry in galleryEntries) {
      await _tap(tester, 'page-${entry.id}');
      for (final scheme in ['white', 'gray10', 'gray90', 'gray100']) {
        await _tap(tester, 'setting-scheme-$scheme');
      }
      await _tap(tester, 'setting-density-touch');
      await _tap(tester, 'setting-density-compact');
      await _tap(tester, 'setting-direction-rtl');
      await _tap(tester, 'setting-textScale-2.0');
      await _tap(tester, 'setting-density-touch');
      await _tap(tester, 'setting-motion-on');
      await _tap(tester, 'setting-width-phone320');
      // Reset so each page starts from the defaults.
      await _tap(tester, 'setting-density-compact');
      await _tap(tester, 'setting-direction-ltr');
      await _tap(tester, 'setting-textScale-1.0');
      await _tap(tester, 'setting-motion-off');
      await _tap(tester, 'setting-width-fill');
      await _tap(tester, 'setting-scheme-white');
    }
  });

  testWidgets('wide layout lists pages and applies a fixed width', (
    tester,
  ) async {
    useSize(tester, const Size(1400, 900));
    await tester.pumpWidget(const GalleryApp());
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-toggle')), findsNothing);
    for (final entry in galleryEntries) {
      await _tap(tester, 'page-${entry.id}');
    }
    await _tap(tester, 'setting-width-phone390');
    await _tap(tester, 'setting-width-desktop1280');
    await _tap(tester, 'setting-direction-rtl');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings change keeps the page mounted', (tester) async {
    useSize(tester, const Size(1400, 900));
    await tester.pumpWidget(const GalleryApp());
    await tester.pump();
    final before = tester.element(find.byType(Directionality).last);
    await _tap(tester, 'setting-scheme-gray90');
    await _tap(tester, 'setting-density-touch');
    final after = tester.element(find.byType(Directionality).last);
    expect(identical(before, after), isTrue);
  });
}
