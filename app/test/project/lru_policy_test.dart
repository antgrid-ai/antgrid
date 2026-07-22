import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/lru_policy.dart';

void main() {
  group('selectEvictionVictim', () {
    test('returns null when no candidates', () {
      expect(
        selectEvictionVictim(open: const [], lastFocused: const {}),
        isNull,
      );
    });

    test('returns the oldest project', () {
      final now = DateTime(2026, 5, 15);
      final result = selectEvictionVictim(
        open: const ['a', 'b', 'c'],
        lastFocused: {
          'a': now.subtract(const Duration(minutes: 10)),
          'b': now.subtract(const Duration(minutes: 5)),
          'c': now.subtract(const Duration(minutes: 1)),
        },
      );
      expect(result, 'a');
    });

    test('protect skips the just-touched id', () {
      final now = DateTime(2026, 5, 15);
      final result = selectEvictionVictim(
        open: const ['a', 'b', 'c'],
        lastFocused: {
          'a': now.subtract(const Duration(minutes: 10)),
          'b': now.subtract(const Duration(minutes: 5)),
          'c': now.subtract(const Duration(minutes: 1)),
        },
        protect: 'a',
      );
      expect(result, 'b');
    });

    test('projects without a lastFocused timestamp evict first', () {
      final now = DateTime.now();
      final result = selectEvictionVictim(
        open: const ['a', 'b', 'c'],
        lastFocused: {'a': now, 'c': now},
      );
      expect(result, 'b');
    });
  });
}
