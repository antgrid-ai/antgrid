import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

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

Widget _top(Widget child) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: 480, child: child),
);

void main() {
  testWidgets('a notification that becomes an error announces the failure', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final sent = _captureAnnouncements(tester);
    await pumpCarbon(
      tester,
      _top(
        const CarbonNotification(title: 'Uploading', announce: true),
      ),
    );
    await tester.pump();
    expect(sent, isEmpty);

    await pumpCarbon(
      tester,
      _top(
        const CarbonNotification(
          kind: CarbonNotificationKind.error,
          title: 'Upload failed',
        ),
      ),
    );
    await tester.pump();
    expect(sent, hasLength(1));
    final data = sent.single['data']! as Map<Object?, Object?>;
    expect(data['message'], contains('Upload failed'));
    expect(data['assertiveness'], 1);
    handle.dispose();
  });

  group('toast stack', () {
    late CarbonToastController controller;

    setUp(() => controller = CarbonToastController());
    tearDown(() => controller.dispose());

    Widget overlay({int maxVisible = 4, double height = 360}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: height,
        width: 400,
        child: CarbonToastOverlay(
          controller: controller,
          maxVisible: maxVisible,
          child: const SizedBox.expand(),
        ),
      ),
    );

    testWidgets('a tall stack at large text scrolls instead of clipping', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        overlay(),
        size: const Size(800, 600),
        textScale: 2,
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      for (var i = 0; i < 4; i++) {
        controller.show(
          title: 'Toast $i',
          subtitle: 'A subtitle long enough to wrap over several lines here.',
        );
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Toast 3'),
        50,
        scrollable: find.byType(Scrollable),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(CarbonButton).last).bottom,
        lessThanOrEqualTo(360),
      );
    });

    testWidgets('toasts waiting past maxVisible are counted on screen', (
      tester,
    ) async {
      await pumpCarbon(tester, overlay(height: 600), size: const Size(800, 600));
      final handles = [
        for (var i = 0; i < 5; i++) controller.show(title: 'Toast $i'),
      ];
      await tester.pump();
      expect(find.text('Toast 4'), findsNothing);
      expect(find.text('1 more'), findsOneWidget);
      handles.first.dismiss();
      await tester.pump();
      expect(find.text('Toast 4'), findsOneWidget);
      expect(find.text('1 more'), findsNothing);
    });

    testWidgets('auto-dismiss waits while a screen reader is on', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: overlay(),
          ),
        ),
        size: const Size(800, 600),
      );
      controller.show(
        title: 'Saved',
        autoDismiss: const Duration(seconds: 1),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('dismissing a handle after the controller is disposed is safe', (
      tester,
    ) async {
      final owned = CarbonToastController();
      final handle = owned.show(title: 'Uploading');
      owned.dispose();
      expect(handle.dismiss, returnsNormally);
      expect(handle.isShowing, isFalse);
    });
  });
}
