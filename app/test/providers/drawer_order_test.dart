import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/drawer_order.dart';

void main() {
  group('reorderIds', () {
    test('drag down: from=0, to=2 in [a,b,c] → [b,a,c]', () {
      expect(reorderIds(['a', 'b', 'c'], 0, 2), ['b', 'a', 'c']);
    });

    test('drag to end: from=0, to=length in [a,b,c] → [b,c,a]', () {
      expect(reorderIds(['a', 'b', 'c'], 0, 3), ['b', 'c', 'a']);
    });

    test('drag up: from=2, to=0 in [a,b,c] → [c,a,b]', () {
      expect(reorderIds(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
    });

    test('drag up by one: from=2, to=1 in [a,b,c] → [a,c,b]', () {
      expect(reorderIds(['a', 'b', 'c'], 2, 1), ['a', 'c', 'b']);
    });

    test('same-slot drop returns null (no-op): from=1, to=1', () {
      expect(reorderIds(['a', 'b', 'c'], 1, 1), isNull);
    });

    test('downward drop into same slot returns null: from=1, to=2', () {
      // ReorderableListView reports to=from+1 when the user drops on the
      // adjacent downward slot — that should be a no-op, not a swap.
      expect(reorderIds(['a', 'b', 'c'], 1, 2), isNull);
    });

    test('out-of-range from returns null', () {
      expect(reorderIds(['a', 'b'], 5, 0), isNull);
      expect(reorderIds(['a', 'b'], -1, 0), isNull);
    });

    test('does not mutate input', () {
      final input = ['a', 'b', 'c'];
      reorderIds(input, 0, 2);
      expect(input, ['a', 'b', 'c']);
    });

    test('empty list returns null for any move', () {
      expect(reorderIds(const [], 0, 0), isNull);
    });
  });
}
