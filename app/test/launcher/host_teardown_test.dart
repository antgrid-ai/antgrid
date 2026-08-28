import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/host_teardown.dart';
import 'package:flutter_test/flutter_test.dart';

class _Host extends HostController {
  _Host(this._drain);

  final Future<void> Function() _drain;
  int drains = 0;

  @override
  Future<void> shutdownOwnedHost() {
    drains++;
    return _drain();
  }
}

void main() {
  group('HostTeardownObserver', () {
    test('lets a quick drain finish before exiting', () async {
      final host = _Host(() async {});
      final observer = HostTeardownObserver(
        host: host,
        budget: const Duration(seconds: 5),
      );

      expect(await observer.didRequestAppExit(), AppExitResponse.exit);
      expect(host.drains, 1);
    });

    test('exits on the budget rather than waiting on a wedged host', () async {
      // The regression this guards: on macOS Sparkle waits on the process
      // before swapping the bundle, so an unbounded await here stalls the
      // update behind the quit — not just the quit.
      final host = _Host(() => Completer<void>().future);
      final observer = HostTeardownObserver(
        host: host,
        budget: const Duration(milliseconds: 50),
      );

      expect(
        await observer.didRequestAppExit().timeout(const Duration(seconds: 2)),
        AppExitResponse.exit,
      );
      expect(host.drains, 1);
    });

    test('a throwing drain still exits', () async {
      final host = _Host(() async => throw StateError('no host'));
      final observer = HostTeardownObserver(host: host);

      expect(await observer.didRequestAppExit(), AppExitResponse.exit);
    });
  });
}
