import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/screen_models.dart';
import 'package:antgrid/services/screen_share_backend.dart';
import 'package:antgrid/services/screen_share_service.dart';
import 'package:antgrid/services/screen_view_service.dart';
import 'package:antgrid/widgets/screen_preview_panel.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 400, child: child)),
  );

  /// Every state must say something. A screen session that produced no picture
  /// is the case most likely to reach a user, and the failure mode this guards
  /// is rendering it as an unexplained black rectangle.
  Iterable<String> visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.trim().isNotEmpty);

  group('ScreenViewStateView', () {
    testWidgets('every stage renders something a user can read', (
      tester,
    ) async {
      for (final stage in ScreenViewStage.values) {
        await tester.pumpWidget(
          host(
            ScreenViewStateView(
              state: ScreenViewState(
                stage: stage,
                reason: 'because',
                windowTitle: 'Notepad',
                frameSize: const ScreenFrameSize(800, 600),
              ),
              // Deliberately no liveBody: the live stage without a first frame
              // is itself a state, not an empty one.
              onRequest: () {},
              onStop: () {},
            ),
          ),
        );
        await tester.pump();
        expect(
          visibleText(tester),
          isNotEmpty,
          reason: '$stage rendered no text',
        );
      }
    });

    testWidgets('idle offers both ends of the choice', (tester) async {
      // Which end picks is the difference between a session that can start with
      // nobody at the host machine and one that cannot, so both are on offer and
      // they are not the same button.
      var requested = 0;
      var hostPicks = 0;
      await tester.pumpWidget(
        host(
          ScreenViewStateView(
            state: const ScreenViewState(),
            onRequest: () => requested++,
            onHostPicks: () => hostPicks++,
          ),
        ),
      );

      expect(find.text('Preview a desktop app'), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-view-request')));
      expect(requested, 1);
      expect(hostPicks, 0);

      await tester.tap(find.byKey(const Key('screen-view-request-host-picks')));
      expect(hostPicks, 1);
      expect(requested, 1);
    });

    testWidgets('the catalog is a list of titles and nothing more', (
      tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        host(
          ScreenViewStateView(
            state: const ScreenViewState(
              stage: ScreenViewStage.choosingWindow,
              windows: [
                ScreenWindowEntry(id: '11', title: 'Claude'),
                ScreenWindowEntry(id: '22', title: 'Ledger'),
              ],
            ),
            onPickWindow: (id) => picked = id,
          ),
        ),
      );

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Ledger'), findsOneWidget);
      // No thumbnails: the catalog must not carry a picture of a window nobody
      // has agreed to share.
      expect(find.byType(Image), findsNothing);

      await tester.tap(find.text('Ledger'));
      expect(picked, '22');
    });

    testWidgets('an empty catalog explains itself rather than hanging', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(stage: ScreenViewStage.choosingWindow),
          ),
        ),
      );

      expect(find.byKey(const Key('screen-view-no-windows')), findsOneWidget);
    });

    testWidgets('requesting and connecting are distinct waits', (tester) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(stage: ScreenViewStage.requesting),
          ),
        ),
      );
      expect(find.text('asking the desktop app...'), findsOneWidget);

      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(
              stage: ScreenViewStage.connecting,
              windowTitle: 'Notepad',
            ),
          ),
        ),
      );
      expect(find.text('connecting to Notepad...'), findsOneWidget);
    });

    testWidgets('no-host explains that the desktop app must be running', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(stage: ScreenViewStage.noHost),
          ),
        ),
      );

      expect(find.text('No desktop app running there'), findsOneWidget);
      expect(find.textContaining('desktop app open'), findsOneWidget);
    });

    testWidgets('awaiting-consent says the choice is not the viewer\'s', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(stage: ScreenViewStage.awaitingConsent),
          ),
        ),
      );

      expect(find.text('Waiting for a window to be picked'), findsOneWidget);
      expect(find.textContaining('Nothing is captured'), findsOneWidget);
    });

    testWidgets('live without a frame yet shows a wait, not a void', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(
              stage: ScreenViewStage.live,
              windowTitle: 'Notepad',
              frameSize: ScreenFrameSize(1440, 900),
            ),
          ),
        ),
      );

      expect(find.text('Notepad'), findsOneWidget);
      expect(find.text('1440x900'), findsOneWidget);
      expect(find.byType(AbLoading), findsOneWidget);
    });

    testWidgets('live renders the supplied body and the control toggle', (
      tester,
    ) async {
      bool? toggled;
      await tester.pumpWidget(
        host(
          ScreenViewStateView(
            state: const ScreenViewState(
              stage: ScreenViewStage.live,
              windowTitle: 'Notepad',
              frameSize: ScreenFrameSize(1440, 900),
            ),
            liveBody: const ColoredBox(color: Color(0xFF000000)),
            onToggleControl: (v) => toggled = v,
          ),
        ),
      );

      expect(find.byType(AbLoading), findsNothing);
      await tester.tap(find.text('CONTROL'));
      expect(toggled, isFalse);
    });

    testWidgets('an interruption labels the last frame instead of hiding it', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(
              stage: ScreenViewStage.interrupted,
              reason: kViewerInterruptedReason,
              windowTitle: 'Notepad',
              frameSize: ScreenFrameSize(1440, 900),
            ),
            liveBody: ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      );

      // The picture stays — the path is expected back — but a still frame with
      // nothing said about it is exactly what reads as a working session.
      expect(find.byType(ColoredBox), findsWidgets);
      expect(find.text(kViewerInterruptedReason), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('a minimised window is its own error, not a generic end', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(
              stage: ScreenViewStage.ended,
              reason: kMinimisedReason,
            ),
          ),
        ),
      );

      expect(find.text('That window was minimised'), findsOneWidget);
      expect(find.text(kMinimisedReason), findsOneWidget);
    });

    testWidgets('a generic end carries the host\'s reason verbatim', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(
              stage: ScreenViewStage.ended,
              reason: 'The connection to the viewer dropped.',
            ),
          ),
        ),
      );

      expect(find.text('The screen session ended'), findsOneWidget);
      expect(
        find.text('The connection to the viewer dropped.'),
        findsOneWidget,
      );
    });

    testWidgets('unsupported names itself rather than showing a dead button', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ScreenViewStateView(
            state: ScreenViewState(
              stage: ScreenViewStage.unsupported,
              reason: kViewerLocalSessionReason,
            ),
          ),
        ),
      );

      expect(find.text('Not available here'), findsOneWidget);
      expect(find.text('Request a window'), findsNothing);
    });
  });

  group('ScreenHostStateView', () {
    testWidgets('every stage renders something a user can read', (
      tester,
    ) async {
      for (final stage in ScreenShareStage.values) {
        await tester.pumpWidget(
          host(
            ScreenHostStateView(
              state: ScreenShareState(
                stage: stage,
                reason: 'because',
                windowTitle: 'Notepad',
                frameSize: const ScreenFrameSize(800, 600),
              ),
              canHost: true,
              onChooseWindow: () {},
              onStop: () {},
            ),
          ),
        );
        await tester.pump();
        expect(
          visibleText(tester),
          isNotEmpty,
          reason: '$stage rendered no text',
        );
      }
    });

    testWidgets('a machine that cannot capture says so instead of offering', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(),
            canHost: false,
            onChooseWindow: () {},
          ),
        ),
      );

      expect(find.text('Window sharing is not available here'), findsOneWidget);
      expect(find.text(kUnsupportedPlatformReason), findsOneWidget);
      expect(find.text('Choose a window'), findsNothing);
    });

    testWidgets('a remote request offers both picking and declining', (
      tester,
    ) async {
      var chosen = 0;
      var declined = 0;
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(
              stage: ScreenShareStage.awaitingConsent,
            ),
            canHost: true,
            onChooseWindow: () => chosen++,
            onStop: () => declined++,
          ),
        ),
      );

      expect(find.text('A device asked to see a window'), findsOneWidget);
      await tester.tap(find.text('Choose a window'));
      await tester.tap(find.text('Decline'));
      expect(chosen, 1);
      expect(declined, 1);
    });

    testWidgets('a live session with no input path explains the gap', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(
              stage: ScreenShareStage.live,
              windowTitle: 'Notepad',
              frameSize: ScreenFrameSize(1440, 900),
              reason: 'That app runs as administrator.',
              viewerConnected: true,
            ),
            canHost: true,
            onStop: () {},
          ),
        ),
      );

      // "My clicks do nothing" is unexplainable to a user otherwise.
      expect(find.text('That app runs as administrator.'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
    });

    testWidgets('a live session with input active shows no warning', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(
              stage: ScreenShareStage.live,
              windowTitle: 'Notepad',
              inputActive: true,
              viewerConnected: true,
            ),
            canHost: true,
            onStop: () {},
          ),
        ),
      );

      expect(find.textContaining('Sharing'), findsOneWidget);
      expect(find.textContaining('unavailable'), findsNothing);
    });

    testWidgets('an armed session with no viewer says so, and blames nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            // What the host looks like for its whole life when the user shares
            // from the machine that owns the window and no device ever answers.
            state: const ScreenShareState(
              stage: ScreenShareStage.live,
              windowTitle: 'Notepad',
              reason: kAwaitingFrameSizeReason,
            ),
            canHost: true,
            onStop: () {},
          ),
        ),
      );

      expect(find.textContaining('Ready to share'), findsOneWidget);
      expect(find.textContaining('Waiting for a device'), findsOneWidget);
      // The whole point: with no viewer there is no input path to be missing,
      // so an input warning here reads as a fault in a session that has none.
      expect(find.text(kAwaitingFrameSizeReason), findsNothing);
      expect(find.text('Stop sharing'), findsOneWidget);
    });

    testWidgets('an interrupted session is not mistaken for an unwatched one', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(
              stage: ScreenShareStage.interrupted,
              windowTitle: 'Notepad',
              reason: kPeerInterruptedReason,
              viewerConnected: true,
            ),
            canHost: true,
            onStop: () {},
          ),
        ),
      );

      expect(find.text('Reconnecting to the viewer'), findsOneWidget);
      expect(find.text(kPeerInterruptedReason), findsOneWidget);
    });

    testWidgets('a machine nothing can reach offers the fix, not the picker', (
      tester,
    ) async {
      var resolved = 0;
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(),
            canHost: true,
            blocker: ScreenHostBlocker.remoteAccessOff,
            onChooseWindow: () {},
            onResolveBlocker: () => resolved++,
          ),
        ),
      );

      // Offering the picker here walks the user through choosing a window for a
      // session that cannot have a viewer.
      expect(find.text('Choose a window'), findsNothing);
      await tester.tap(find.text('Turn on remote access'));
      expect(resolved, 1);
    });

    testWidgets('screen control off is named as the setting it is', (
      tester,
    ) async {
      var resolved = 0;
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(),
            canHost: true,
            blocker: ScreenHostBlocker.screenControlOff,
            onChooseWindow: () {},
            onResolveBlocker: () => resolved++,
          ),
        ),
      );

      expect(find.text('Screen control is off'), findsOneWidget);
      expect(find.text('Choose a window'), findsNothing);
      await tester.tap(find.text('Turn on screen control'));
      expect(resolved, 1);
    });

    testWidgets('an unread switch blocks nothing', (tester) async {
      await tester.pumpWidget(
        host(
          ScreenHostStateView(
            state: const ScreenShareState(),
            canHost: true,
            // Null is "not known yet", which must not be reported as "off" —
            // the bridge is still the authority and will say so itself.
            onChooseWindow: () {},
          ),
        ),
      );

      expect(find.text('Choose a window'), findsOneWidget);
    });
  });
}
