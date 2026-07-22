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
}
