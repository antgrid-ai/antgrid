import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _top(Widget child, {double width = 480}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

String _kindName(CarbonNotificationKind kind) => switch (kind) {
  CarbonNotificationKind.info => 'Information',
  CarbonNotificationKind.success => 'Success',
  CarbonNotificationKind.warning => 'Warning',
  CarbonNotificationKind.error => 'Error',
};

/// Records what is sent to the platform accessibility channel.
List<Map<Object?, Object?>> _captureAnnouncements(WidgetTester tester) {
  final sent = <Map<Object?, Object?>>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (message) async {
      if (message is Map && message['type'] == 'announce') {
        sent.add(Map<Object?, Object?>.from(message));
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return sent;
}

void main() {
  group('inline notification', () {
    testWidgets('every kind shows a labelled icon, never color alone', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final kind in CarbonNotificationKind.values) {
        await pumpCarbon(
          tester,
          _top(
            CarbonNotification(
              kind: kind,
              title: 'Build finished',
              subtitle: 'All checks ran.',
              announce: false,
            ),
          ),
        );
        final finder = find.bySemanticsLabel(RegExp(_kindName(kind)));
        expect(finder, findsOneWidget, reason: '$kind');
        final label = tester.getSemantics(finder).label;
        expect(label, contains('Build finished'));
        expect(label, contains('All checks ran.'));
      }
      handle.dispose();
    });

    testWidgets('kind names come from the localizations', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        CarbonLocalizationsScope(
          messages: const CarbonLocalizations(error: 'Fehler'),
          child: _top(
            const CarbonNotification(
              kind: CarbonNotificationKind.error,
              title: 'Kaputt',
              announce: false,
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('Fehler')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('uses the notification surface and support accent', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      for (final (kind, bg, accent) in [
        (
          CarbonNotificationKind.info,
          theme.colors.notificationBackgroundInfo,
          theme.colors.supportInfo,
        ),
        (
          CarbonNotificationKind.success,
          theme.colors.notificationBackgroundSuccess,
          theme.colors.supportSuccess,
        ),
        (
          CarbonNotificationKind.warning,
          theme.colors.notificationBackgroundWarning,
          theme.colors.supportWarning,
        ),
        (
          CarbonNotificationKind.error,
          theme.colors.notificationBackgroundError,
          theme.colors.supportError,
        ),
      ]) {
        await pumpCarbon(
          tester,
          _top(CarbonNotification(kind: kind, title: 'T', announce: false)),
        );
        final box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(CarbonNotification),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.color, bg, reason: '$kind');
        expect(
          (decoration.border! as BorderDirectional).start.color,
          accent,
          reason: '$kind',
        );
      }
    });

    testWidgets('high contrast uses the inverse surface', (tester) async {
      final colors = CarbonThemeData().colors;
      await pumpCarbon(
        tester,
        _top(
          const CarbonNotification(
            title: 'T',
            highContrast: true,
            announce: false,
          ),
        ),
      );
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CarbonNotification),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, colors.backgroundInverse);
      expect(
        (decoration.border! as BorderDirectional).start.color,
        colors.supportInfoInverse,
      );
    });

    testWidgets('close and action are separate and independent', (
      tester,
    ) async {
      var actions = 0;
      var closes = 0;
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(
            kind: CarbonNotificationKind.warning,
            title: 'Disk almost full',
            subtitle: 'Free some space.',
            announce: false,
            action: CarbonNotificationAction(
              label: 'Clean up',
              onPressed: () => actions++,
            ),
            onClose: () => closes++,
          ),
        ),
      );
      await tester.tap(find.text('Clean up'));
      expect((actions, closes), (1, 0));
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel == 'Close notification',
        ),
      );
      expect((actions, closes), (1, 1));
    });

    testWidgets('close appears only with onClose, named from localizations', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _top(const CarbonNotification(title: 'T', announce: false)),
      );
      expect(find.byType(CarbonButton), findsNothing);
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(title: 'T', announce: false, onClose: () {}),
        ),
      );
      expect(find.bySemanticsLabel('Close notification'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the component never dismisses itself', (tester) async {
      var closes = 0;
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(
            title: 'T',
            announce: false,
            onClose: () => closes++,
          ),
        ),
      );
      await tester.pump(const Duration(minutes: 5));
      expect(find.byType(CarbonNotification), findsOneWidget);
      expect(closes, 0);
    });

    testWidgets('action stays keyboard reachable before close', (
      tester,
    ) async {
      var actions = 0;
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(
            title: 'T',
            announce: false,
            action: CarbonNotificationAction(
              label: 'Retry',
              onPressed: () => actions++,
            ),
            onClose: () {},
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(actions, 1);
    });

    testWidgets('tertiary action kind is honored', (tester) async {
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(
            title: 'T',
            announce: false,
            action: CarbonNotificationAction(
              label: 'Go',
              kind: CarbonButtonKind.tertiary,
              onPressed: () {},
            ),
          ),
        ),
      );
      expect(
        tester.widget<CarbonButton>(find.byType(CarbonButton)).kind,
        CarbonButtonKind.tertiary,
      );
    });
  });

  group('announcements', () {
    testWidgets('info and success are polite live regions, announced by the platform', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final sent = _captureAnnouncements(tester);
      for (final kind in [
        CarbonNotificationKind.info,
        CarbonNotificationKind.success,
      ]) {
        await pumpCarbon(
          tester,
          _top(CarbonNotification(kind: kind, title: 'Saved')),
        );
        await tester.pump();
        final node = tester.getSemantics(
          find.bySemanticsLabel(RegExp(_kindName(kind))),
        );
        expect(node.flagsCollection.isLiveRegion, isTrue, reason: '$kind');
      }
      expect(sent, isEmpty, reason: 'no duplicate explicit announcement');
      handle.dispose();
    });

    testWidgets('error and warning announce assertively once', (tester) async {
      final handle = tester.ensureSemantics();
      final sent = _captureAnnouncements(tester);
      await pumpCarbon(
        tester,
        _top(
          const CarbonNotification(
            kind: CarbonNotificationKind.error,
            title: 'Upload failed',
            subtitle: 'Try again.',
          ),
        ),
      );
      await tester.pump();
      expect(sent, hasLength(1));
      final data = sent.single['data']! as Map<Object?, Object?>;
      expect(data['message'], 'Error. Upload failed. Try again.');
      expect(data['assertiveness'], 1);

      // New text on the same notification is a rebuild, not a new message.
      await pumpCarbon(
        tester,
        _top(
          const CarbonNotification(
            kind: CarbonNotificationKind.error,
            title: 'Upload failed again',
          ),
        ),
      );
      await tester.pump();
      expect(sent, hasLength(1));

      await pumpCarbon(
        tester,
        _top(
          const CarbonNotification(
            kind: CarbonNotificationKind.warning,
            title: 'Careful',
          ),
        ),
      );
      await tester.pump();
      expect(sent, hasLength(1), reason: 'same element, kind change only');
      handle.dispose();
    });

    testWidgets('a newly shown notification announces again', (tester) async {
      final handle = tester.ensureSemantics();
      final sent = _captureAnnouncements(tester);
      Widget one(Key key) => _top(
        CarbonNotification(
          key: key,
          kind: CarbonNotificationKind.error,
          title: 'Failed',
        ),
      );
      await pumpCarbon(tester, one(const ValueKey('a')));
      await tester.pump();
      await pumpCarbon(tester, one(const ValueKey('b')));
      await tester.pump();
      expect(sent, hasLength(2));
      handle.dispose();
    });

    testWidgets('announce false stays silent', (tester) async {
      final sent = _captureAnnouncements(tester);
      await pumpCarbon(
        tester,
        _top(
          const CarbonNotification(
            kind: CarbonNotificationKind.error,
            title: 'Already visible',
            announce: false,
          ),
        ),
      );
      await tester.pump();
      expect(sent, isEmpty);
    });
  });

  group('layout and live configuration', () {
    testWidgets('minimum height, and growth for long text at 200%', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _top(const CarbonNotification(title: 'T', announce: false)),
      );
      expect(
        tester.getSize(find.byType(CarbonNotification)).height,
        greaterThanOrEqualTo(48),
      );
      await pumpCarbon(
        tester,
        SingleChildScrollView(child: _top(
          CarbonNotification(
            title: 'A rather long notification title that wraps',
            subtitle: 'And an equally long subtitle ' * 4,
            announce: false,
            action: CarbonNotificationAction(label: 'Open the details', onPressed: () {}),
            onClose: () {},
          ),
          width: 320,
        )),
        textScale: 2,
        size: const Size(320, 800),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(CarbonNotification)).height,
        greaterThan(150),
      );
      expect(tester.getSize(find.byType(CarbonNotification)).width, 320);
    });

    testWidgets('touch density makes the action and close 48 high', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(
            title: 'T',
            announce: false,
            action: CarbonNotificationAction(label: 'Go', onPressed: () {}),
            onClose: () {},
          ),
        ),
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      for (final b in tester.widgetList<CarbonButton>(find.byType(CarbonButton))) {
        expect(
          tester.getSize(find.byWidget(b)).height,
          greaterThanOrEqualTo(48),
        );
      }
    });

    testWidgets('RTL puts the close button at the start side', (tester) async {
      await pumpCarbon(
        tester,
        _top(CarbonNotification(title: 'T', announce: false, onClose: () {})),
        dir: TextDirection.rtl,
        size: const Size(600, 400),
      );
      final close = tester.getCenter(find.byType(CarbonButton));
      final icon = tester.getCenter(find.byType(CarbonIcon).first);
      expect(close.dx, lessThan(icon.dx));
    });

    testWidgets('theme switch updates colors in place', (tester) async {
      final harness = await pumpCarbon(
        tester,
        _top(const CarbonNotification(title: 'T', announce: false)),
      );
      Color fill() =>
          (tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(CarbonNotification),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration)
              .color!;
      final dark = CarbonThemeData(scheme: CarbonThemeScheme.gray100);
      await harness.setTheme(tester, dark);
      expect(fill(), dark.colors.notificationBackgroundInfo);
    });
  });

  group('toasts', () {
    late CarbonToastController controller;

    setUp(() => controller = CarbonToastController());


    Widget overlay({
      Widget? child,
      AlignmentGeometry alignment = AlignmentDirectional.topEnd,
      int maxVisible = 4,
    }) => CarbonToastOverlay(
      controller: controller,
      alignment: alignment,
      maxVisible: maxVisible,
      child: child ?? const SizedBox.expand(),
    );

    testWidgets('stack in order at the corner and dismiss individually', (
      tester,
    ) async {
      await pumpCarbon(tester, overlay(), size: const Size(800, 600));
      final a = controller.show(title: 'First', kind: CarbonNotificationKind.success);
      controller.show(title: 'Second');
      controller.show(title: 'Third', kind: CarbonNotificationKind.error);
      await tester.pump();
      expect(find.byType(CarbonToast), findsNWidgets(3));
      final tops = [
        for (final t in ['First', 'Second', 'Third'])
          tester.getTopLeft(find.text(t)).dy,
      ];
      expect(tops, [...tops]..sort());
      expect(tester.getTopRight(find.byType(CarbonToast).first).dx, 800 - 16);

      expect(a.isShowing, isTrue);
      a.dismiss();
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(find.byType(CarbonToast), findsNWidgets(2));
      expect(a.isShowing, isFalse);
      a.dismiss();

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Second'),
            matching: find.byType(CarbonToast),
          ),
          matching: find.byType(CarbonButton),
        ),
      );
      await tester.pump();
      expect(find.text('Second'), findsNothing);
      expect(controller.length, 1);
      controller.dismissAll();
      await tester.pump();
      expect(find.byType(CarbonToast), findsNothing);
    });

    testWidgets('corner follows text direction and safe area', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 20);
      addTearDown(tester.view.resetPadding);
      await pumpCarbon(
        tester,
        overlay(),
        size: const Size(800, 600),
        dir: TextDirection.rtl,
      );
      controller.show(title: 'Hello');
      await tester.pump();
      final rect = tester.getRect(find.byType(CarbonToast));
      expect(rect.left, 16);
      expect(rect.top, 40 + 16);

      await pumpCarbon(
        tester,
        overlay(alignment: AlignmentDirectional.bottomEnd),
        size: const Size(800, 600),
      );
      await tester.pump();
      final bottom = tester.getRect(find.byType(CarbonToast));
      expect(bottom.right, 800 - 16);
      expect(bottom.bottom, lessThanOrEqualTo(600 - 20 - 16));
    });

    testWidgets('does not block the UI underneath', (tester) async {
      var taps = 0;
      await pumpCarbon(
        tester,
        overlay(
          child: Align(
            alignment: Alignment.center,
            child: CarbonButton(label: 'Underneath', onPressed: () => taps++),
          ),
        ),
        size: const Size(800, 600),
      );
      controller.show(title: 'Toast');
      await tester.pump();
      await tester.tap(find.text('Underneath'));
      expect(taps, 1);
      // Even the empty corner area beside the toast passes taps through.
      await tester.tapAt(const Offset(10, 300));
      expect(tester.takeException(), isNull);
    });

    testWidgets('never auto-dismisses by default', (tester) async {
      await pumpCarbon(tester, overlay());
      controller.show(title: 'Stays');
      await tester.pump();
      await tester.pump(const Duration(minutes: 10));
      expect(find.text('Stays'), findsOneWidget);
    });

    testWidgets('opt-in timeout dismisses and pauses on hover', (
      tester,
    ) async {
      await pumpCarbon(tester, overlay(), size: const Size(800, 600));
      controller.show(
        title: 'Brief',
        autoDismiss: const Duration(seconds: 4),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Brief'), findsOneWidget);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(1, 1));
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('Brief')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Brief'), findsOneWidget, reason: 'paused while hovered');

      await gesture.moveTo(const Offset(1, 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Brief'), findsOneWidget, reason: 'about 2s remain');
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Brief'), findsNothing);
    });

    testWidgets('timeout pauses while focus is inside the toast', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await pumpCarbon(tester, overlay(), size: const Size(800, 600));
      controller.show(
        title: 'Focus me',
        autoDismiss: const Duration(seconds: 3),
        action: CarbonNotificationAction(label: 'Undo', onPressed: () {}),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('Focus me'), findsOneWidget);
    });

    testWidgets('timers are cancelled when the overlay unmounts', (
      tester,
    ) async {
      await pumpCarbon(tester, overlay());
      controller.show(title: 'Brief', autoDismiss: const Duration(seconds: 4));
      await tester.pump();
      await pumpCarbon(tester, const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('action does not dismiss; host dismisses through the handle', (
      tester,
    ) async {
      await pumpCarbon(tester, overlay());
      late CarbonToastHandle handle;
      var undone = 0;
      handle = controller.show(
        title: 'Deleted',
        action: CarbonNotificationAction(
          label: 'Undo',
          onPressed: () {
            undone++;
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1);
      expect(find.text('Deleted'), findsOneWidget);
      handle.dismiss();
      await tester.pump();
      expect(find.text('Deleted'), findsNothing);
    });

    testWidgets('dismissible false omits the close button', (tester) async {
      await pumpCarbon(tester, overlay());
      controller.show(title: 'Pinned', dismissible: false);
      await tester.pump();
      expect(find.byType(CarbonButton), findsNothing);
    });

    testWidgets('maxVisible caps the stack, oldest first', (tester) async {
      await pumpCarbon(tester, overlay(maxVisible: 2));
      for (var i = 0; i < 4; i++) {
        controller.show(title: 'Toast $i');
      }
      await tester.pump();
      expect(find.byType(CarbonToast), findsNWidgets(2));
      expect(find.text('Toast 0'), findsOneWidget);
      expect(find.text('Toast 1'), findsOneWidget);
      controller.dismiss(0);
      await tester.pump();
      expect(find.text('Toast 2'), findsOneWidget);
    });

    testWidgets('error toast announces assertively when shown', (tester) async {
      final handle = tester.ensureSemantics();
      final sent = _captureAnnouncements(tester);
      await pumpCarbon(tester, overlay());
      controller.show(kind: CarbonNotificationKind.error, title: 'Sync failed');
      await tester.pump();
      await tester.pump();
      expect(sent, hasLength(1));
      controller.show(kind: CarbonNotificationKind.info, title: 'FYI');
      await tester.pump();
      await tester.pump();
      expect(sent, hasLength(1), reason: 'the first toast is not re-announced');
      handle.dispose();
    });

    testWidgets('toast shows caption and uses the inverse surface', (
      tester,
    ) async {
      await pumpCarbon(tester, overlay());
      controller.show(title: 'Done', subtitle: 'Exported.', caption: '10:42');
      await tester.pump();
      expect(find.text('10:42'), findsOneWidget);
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CarbonToast),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (box.decoration as BoxDecoration).color,
        CarbonThemeData().colors.backgroundInverse,
      );
    });
  });
}
