import 'package:portable_pty/portable_pty.dart';
import 'package:test/test.dart';

/// Concrete class that uses the [PtyListenable] mixin for testing.
class _TestListenable with PtyListenable {}

void main() {
  group('PtyListenable', () {
    late _TestListenable listenable;

    setUp(() {
      listenable = _TestListenable();
    });

    tearDown(() {
      if (!listenable.isDisposed) {
        listenable.dispose();
      }
    });

    test('addListener and notifyListeners calls the callback', () {
      var called = 0;
      listenable.addListener(() => called++);
      listenable.notifyListeners();
      expect(called, 1);
    });

    test('multiple listeners all receive notification', () {
      final calls = <int>[];
      listenable.addListener(() => calls.add(1));
      listenable.addListener(() => calls.add(2));
      listenable.addListener(() => calls.add(3));
      listenable.notifyListeners();
      expect(calls, [1, 2, 3]);
    });

    test('removeListener stops future notifications', () {
      var called = 0;
      void callback() => called++;
      listenable.addListener(callback);
      listenable.notifyListeners();
      expect(called, 1);

      listenable.removeListener(callback);
      listenable.notifyListeners();
      expect(called, 1, reason: 'should not have been called again');
    });

    test('isDisposed starts as false', () {
      expect(listenable.isDisposed, isFalse);
    });

    test('dispose sets isDisposed and clears listeners', () {
      var called = 0;
      listenable.addListener(() => called++);
      listenable.dispose();

      expect(listenable.isDisposed, isTrue);
      listenable.notifyListeners();
      expect(called, 0, reason: 'disposed listenables should not notify');
    });

    test('addListener after dispose is silently ignored', () {
      listenable.dispose();
      var called = 0;
      listenable.addListener(() => called++);
      listenable.notifyListeners();
      expect(called, 0);
    });

    test(
      'listener added during notification is not called until next notify',
      () {
        var innerCalled = 0;
        listenable.addListener(() {
          listenable.addListener(() => innerCalled++);
        });
        listenable.notifyListeners();
        expect(innerCalled, 0, reason: 'newly added listener called too early');

        listenable.notifyListeners();
        expect(innerCalled, greaterThan(0));
      },
    );
  });
}
