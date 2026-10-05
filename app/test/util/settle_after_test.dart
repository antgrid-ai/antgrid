import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/util/settle_after.dart';

void main() {
  test('waits for the burst of updates to go quiet', () {
    fakeAsync((async) {
      final updates = StreamController<int>.broadcast(sync: true);
      var settled = false;
      settleAfter(updates.stream, () {}).then((_) => settled = true);

      async.elapse(const Duration(milliseconds: 200));
      updates.add(1);
      async.elapse(const Duration(milliseconds: 200));
      updates.add(2);
      async.elapse(const Duration(milliseconds: 200));
      expect(settled, isFalse);

      async.elapse(const Duration(milliseconds: 100));
      expect(settled, isTrue);
    });
  });

  test('gives up when no reply ever arrives', () {
    fakeAsync((async) {
      final updates = StreamController<int>.broadcast(sync: true);
      var settled = false;
      settleAfter(
        updates.stream,
        () {},
        quiet: const Duration(seconds: 30),
      ).then((_) => settled = true);

      async.elapse(const Duration(seconds: 4));
      expect(settled, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(settled, isTrue);
    });
  });
}
