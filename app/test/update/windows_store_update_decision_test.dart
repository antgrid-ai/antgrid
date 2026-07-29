import 'package:antgrid/update/windows_store_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercises the pure reply→decision mapping only. The runner's method channel
// (windows/runner/store_update_channel.cpp) does not run under `flutter test`,
// and StoreContext itself needs an MSIX-packaged Store install to exercise.
void main() {
  group('decideStoreUpdate', () {
    test('null reply (channel error path) → none', () {
      expect(decideStoreUpdate(null), StoreUpdateCheck.none);
    });

    test('empty map → none', () {
      expect(decideStoreUpdate({}), StoreUpdateCheck.none);
    });

    test('zero updates → none, even if mandatory is set', () {
      expect(
        decideStoreUpdate({'updateCount': 0, 'mandatory': true}),
        StoreUpdateCheck.none,
      );
    });

    test('updates pending, none mandatory → optional', () {
      expect(
        decideStoreUpdate({'updateCount': 2, 'mandatory': false}),
        StoreUpdateCheck.optional,
      );
    });

    test('updates pending, mandatory → mandatory', () {
      expect(
        decideStoreUpdate({'updateCount': 1, 'mandatory': true}),
        StoreUpdateCheck.mandatory,
      );
    });

    test('missing mandatory key defaults to optional', () {
      expect(
        decideStoreUpdate({'updateCount': 1}),
        StoreUpdateCheck.optional,
      );
    });

    test('malformed updateCount type → none', () {
      expect(
        decideStoreUpdate({'updateCount': 'lots', 'mandatory': true}),
        StoreUpdateCheck.none,
      );
    });

    test('malformed mandatory type degrades to optional, not mandatory', () {
      expect(
        decideStoreUpdate({'updateCount': 1, 'mandatory': 'yes'}),
        StoreUpdateCheck.optional,
      );
    });
  });
}
