import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/util/relative_time.dart';

void main() {
  final now = DateTime(2026, 6, 13, 12, 0, 0);

  test('just now under a minute', () {
    expect(
      relativeTime(now.subtract(const Duration(seconds: 5)), now: now),
      'just now',
    );
  });

  test('minutes', () {
    expect(
      relativeTime(now.subtract(const Duration(minutes: 1)), now: now),
      '1 min ago',
    );
    expect(
      relativeTime(now.subtract(const Duration(minutes: 2)), now: now),
      '2 mins ago',
    );
  });

  test('hours', () {
    expect(
      relativeTime(now.subtract(const Duration(hours: 1)), now: now),
      '1 hour ago',
    );
    expect(
      relativeTime(now.subtract(const Duration(hours: 5)), now: now),
      '5 hours ago',
    );
  });

  test('days', () {
    expect(
      relativeTime(now.subtract(const Duration(days: 2)), now: now),
      '2 days ago',
    );
  });

  test('weeks', () {
    expect(
      relativeTime(now.subtract(const Duration(days: 21)), now: now),
      '3 weeks ago',
    );
  });

  test('months', () {
    expect(
      relativeTime(now.subtract(const Duration(days: 30)), now: now),
      '1 month ago',
    );
    expect(
      relativeTime(now.subtract(const Duration(days: 90)), now: now),
      '3 months ago',
    );
  });

  test('years', () {
    expect(
      relativeTime(now.subtract(const Duration(days: 365)), now: now),
      '1 year ago',
    );
    expect(
      relativeTime(now.subtract(const Duration(days: 800)), now: now),
      '2 years ago',
    );
  });

  test('future or zero clamps to just now', () {
    expect(
      relativeTime(now.add(const Duration(minutes: 5)), now: now),
      'just now',
    );
  });

  group('absoluteTime', () {
    test('afternoon uses 12-hour PM', () {
      expect(absoluteTime(DateTime(2026, 7, 3, 14, 45)), 'Jul 3, 2026, 2:45 PM');
    });
    test('after midnight reads 12:xx AM with padded minutes', () {
      expect(absoluteTime(DateTime(2026, 1, 9, 0, 5)), 'Jan 9, 2026, 12:05 AM');
    });
    test('noon reads 12:00 PM', () {
      expect(absoluteTime(DateTime(2026, 12, 25, 12, 0)), 'Dec 25, 2026, 12:00 PM');
    });
  });
}
