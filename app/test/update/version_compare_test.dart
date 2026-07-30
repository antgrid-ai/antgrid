import 'package:antgrid/update/github_release_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercises the pure installed-version vs release-tag comparison only; the
// network fetch and PackageInfo are exercised on a real build.
void main() {
  group('isNewerVersion', () {
    test('newer patch → true', () {
      expect(isNewerVersion(current: '1.0.6', latestTag: 'v1.0.7'), isTrue);
    });

    test('same version → false', () {
      expect(isNewerVersion(current: '1.0.6', latestTag: 'v1.0.6'), isFalse);
    });

    test('older release than installed → false', () {
      expect(isNewerVersion(current: '1.0.6', latestTag: 'v1.0.5'), isFalse);
    });

    test('major beats minor/patch', () {
      expect(isNewerVersion(current: '1.9.9', latestTag: 'v2.0.0'), isTrue);
    });

    test('numeric compare, not lexicographic', () {
      expect(isNewerVersion(current: '1.9.0', latestTag: 'v1.10.0'), isTrue);
    });

    test('installed build metadata is ignored', () {
      expect(isNewerVersion(current: '1.0.6+7', latestTag: 'v1.0.7'), isTrue);
      expect(isNewerVersion(current: '1.0.6+7', latestTag: 'v1.0.6'), isFalse);
    });

    test('tag without v prefix works', () {
      expect(isNewerVersion(current: '1.0.6', latestTag: '1.0.7'), isTrue);
    });

    test('prerelease tag compares on its core triple', () {
      // releases/latest never returns prereleases; this is defensive only.
      expect(
        isNewerVersion(current: '1.0.6', latestTag: 'v1.1.0-beta.1'),
        isTrue,
      );
      expect(
        isNewerVersion(current: '1.1.0', latestTag: 'v1.1.0-beta.1'),
        isFalse,
      );
    });

    test('malformed tag → false', () {
      expect(isNewerVersion(current: '1.0.6', latestTag: 'latest'), isFalse);
      expect(isNewerVersion(current: '1.0.6', latestTag: 'v1.0'), isFalse);
      expect(isNewerVersion(current: '1.0.6', latestTag: ''), isFalse);
    });

    test('malformed installed version → false', () {
      expect(isNewerVersion(current: 'dev', latestTag: 'v9.9.9'), isFalse);
      expect(isNewerVersion(current: '', latestTag: 'v9.9.9'), isFalse);
    });
  });
}
