import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/utils/notification_routing.dart';

void main() {
  test('parseAbMessage parses terminal:notification', () {
    final msg = parseAbMessage({
      'type': 'terminal:notification',
      'id': 'x',
      'timestamp': 0,
      'terminalId': 't1',
      'kind': 'osc9',
      'body': 'Build finished',
    });
    expect(msg, isA<TerminalNotificationMessage>());
    expect((msg as TerminalNotificationMessage).body, 'Build finished');
    expect(msg.kind, 'osc9');
  });

  group('shouldShowInAppToast', () {
    test('only resumed (focused window) shows the in-app toast', () {
      expect(shouldShowInAppToast(AppLifecycleState.resumed), isTrue);
    });

    test('every non-focused state routes to the OS notification', () {
      // The toast paints inside the app window, so an unfocused window
      // (inactive = occluded behind another app, or minimized) must use the
      // OS notification — the only channel visible above the foreground app.
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        expect(
          shouldShowInAppToast(state),
          isFalse,
          reason: '$state is not focused → OS notification',
        );
      }
    });
  });

  group('isViewingSession', () {
    bool viewing({
      String? sessionId = 's1',
      String? activeSessionId = 's1',
      bool onWorkspaceSurface = true,
      bool agentSurfaceVisible = true,
      AppLifecycleState lifecycle = AppLifecycleState.resumed,
    }) => isViewingSession(
      sessionId: sessionId,
      activeSessionId: activeSessionId,
      onWorkspaceSurface: onWorkspaceSurface,
      agentSurfaceVisible: agentSurfaceVisible,
      lifecycle: lifecycle,
    );

    test('the chat on screen is being viewed (so it must not notify)', () {
      expect(viewing(), isTrue);
    });

    test('another session is NOT being viewed (it must notify)', () {
      // The whole point: an event the user can't see still reaches them.
      expect(viewing(sessionId: 's2'), isFalse);
      expect(viewing(activeSessionId: null), isFalse);
    });

    test('a backgrounded app is viewing nothing', () {
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        expect(viewing(lifecycle: state), isFalse, reason: '$state');
      }
    });

    test('another surface (New Session, settings) is not the chat', () {
      expect(viewing(onWorkspaceSurface: false), isFalse);
    });

    test('the mobile workspace page is not the chat either', () {
      // Mobile swipes between agent and files/git/preview inside ONE surface, so
      // the surface check alone would silence a session the user cannot see.
      expect(viewing(agentSurfaceVisible: false), isFalse);
    });

    test('an unattributed notification always surfaces', () {
      // A hook with no terminal id matches no session, so it can never be
      // suppressed by accident.
      expect(viewing(sessionId: null), isFalse);
      expect(viewing(sessionId: '', activeSessionId: ''), isFalse);
    });
  });
}
