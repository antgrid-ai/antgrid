import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _overlay(CarbonToastController c) => CarbonToastOverlay(controller: c, child: const SizedBox());

void main() {
  group('toast overlay controller swap', () {
    testWidgets('a timed toast on the new controller auto-dismisses', (
      tester,
    ) async {
      final a = CarbonToastController();
      final b = CarbonToastController();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      a.show(title: 'A sticky');
      await pumpCarbon(tester, _overlay(a));
      b.show(title: 'B timed', autoDismiss: const Duration(seconds: 1));
      await pumpCarbon(tester, _overlay(b));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('B timed'), findsNothing);
    });

    testWidgets('a sticky toast on the new controller is not dismissed by the '
        'old controller timer', (tester) async {
      final c = CarbonToastController();
      final d = CarbonToastController();
      addTearDown(c.dispose);
      addTearDown(d.dispose);
      c.show(title: 'C timed', autoDismiss: const Duration(seconds: 1));
      await pumpCarbon(tester, _overlay(c));
      d.show(title: 'D sticky');
      await pumpCarbon(tester, _overlay(d));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('D sticky'), findsOneWidget);
    });
  });

  group('CarbonInteraction highlight mode', () {
    testWidgets('a modality flip does not rebuild unfocused controls', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      var builds = 0;
      await pumpCarbon(
        tester,
        Column(
          children: [
            for (var i = 0; i < 5; i++)
              CarbonInteraction(
                onPressed: () {},

                builder: (context, state, child) {
                  builds++;
                  return const SizedBox(width: 20, height: 20);
                },
              ),
          ],
        ),
      );
      builds = 0;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      expect(builds, 0);
    });

    testWidgets('the focused control still flips focusVisible', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      final node = FocusNode();
      addTearDown(node.dispose);
      bool? visible;
      await pumpCarbon(
        tester,
        CarbonInteraction(
          focusNode: node,
          onPressed: () {},

          builder: (context, state, child) {
            visible = state.focusVisible;
            return const SizedBox(width: 20, height: 20);
          },
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(visible, isFalse);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      expect(visible, isTrue);
    });
  });
}
