import 'package:antgrid/update/ios_app_store_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercises the pure lookup-reply interpretation; the service's fetch/decode
// seams are covered in ios_app_store_service_test.dart, and the underlying
// version comparison in version_compare_test.dart.
void main() {
  Map<String, Object?> reply({
    String? version = '1.0.7',
    String? trackViewUrl = 'https://apps.apple.com/app/id123',
    String? minimumOsVersion,
  }) => {
    'resultCount': 1,
    'results': [
      {
        'version': ?version,
        'trackViewUrl': ?trackViewUrl,
        'minimumOsVersion': ?minimumOsVersion,
      },
    ],
  };

  test('newer store version → available, carrying the listing URL', () {
    final d = decideIosStoreUpdate(
      lookupJson: reply(),
      installedVersion: '1.0.6',
      deviceOsVersion: '18.5',
    );
    expect(d.updateAvailable, isTrue);
    expect(d.listingUrl, 'https://apps.apple.com/app/id123');
  });

  test('same or older store version → unavailable', () {
    for (final v in ['1.0.6', '1.0.5']) {
      final d = decideIosStoreUpdate(
        lookupJson: reply(version: v),
        installedVersion: '1.0.6',
        deviceOsVersion: '18.5',
      );
      expect(d.updateAvailable, isFalse, reason: 'store $v vs installed 1.0.6');
      expect(d.listingUrl, isNull);
    }
  });

  test('empty results (unpublished / wrong storefront) → unavailable', () {
    final d = decideIosStoreUpdate(
      lookupJson: {'resultCount': 0, 'results': <Object?>[]},
      installedVersion: '1.0.6',
      deviceOsVersion: '18.5',
    );
    expect(d.updateAvailable, isFalse);
  });

  test('EMPTY trackViewUrl → unavailable (no dead affordance)', () {
    final d = decideIosStoreUpdate(
      lookupJson: reply(trackViewUrl: ''),
      installedVersion: '1.0.6',
      deviceOsVersion: '18.5',
    );
    expect(d.updateAvailable, isFalse);
    expect(d.listingUrl, isNull);
  });

  test('missing trackViewUrl → unavailable (no dead affordance)', () {
    final d = decideIosStoreUpdate(
      lookupJson: reply(trackViewUrl: null),
      installedVersion: '1.0.6',
      deviceOsVersion: '18.5',
    );
    expect(d.updateAvailable, isFalse);
  });

  test('minimumOsVersion above the device OS → unavailable', () {
    final d = decideIosStoreUpdate(
      lookupJson: reply(minimumOsVersion: '18.0'),
      installedVersion: '1.0.6',
      deviceOsVersion: '17.5',
    );
    expect(d.updateAvailable, isFalse);
  });

  test('minimumOsVersion at or below the device OS → available', () {
    for (final os in ['18.0', '18.5', '19']) {
      final d = decideIosStoreUpdate(
        lookupJson: reply(minimumOsVersion: '18.0'),
        installedVersion: '1.0.6',
        deviceOsVersion: os,
      );
      expect(d.updateAvailable, isTrue, reason: 'device $os vs floor 18.0');
    }
  });

  test('two-component OS strings compare correctly (18.5 vs floor 18.10)', () {
    // Numeric, not lexicographic: "18.10" > "18.5".
    final d = decideIosStoreUpdate(
      lookupJson: reply(minimumOsVersion: '18.10'),
      installedVersion: '1.0.6',
      deviceOsVersion: '18.5',
    );
    expect(d.updateAvailable, isFalse);
  });

  test('OS gate fails open on unparseable or missing input', () {
    for (final (floor, device) in [
      ('garbage', '17.0'),
      ('18.0', null),
      (null, '17.0'),
    ]) {
      final d = decideIosStoreUpdate(
        lookupJson: reply(minimumOsVersion: floor),
        installedVersion: '1.0.6',
        deviceOsVersion: device,
      );
      expect(
        d.updateAvailable,
        isTrue,
        reason: 'floor=$floor device=$device must not suppress the update',
      );
    }
  });

  test('non-semver store version → unavailable (never prompt on garbage)', () {
    final d = decideIosStoreUpdate(
      lookupJson: reply(version: '2.0'),
      installedVersion: '1.0.6',
      deviceOsVersion: '18.5',
    );
    expect(d.updateAvailable, isFalse);
  });

  test('storefrontCountry accepts alpha-2 only', () {
    expect(storefrontCountry('US'), 'US');
    expect(storefrontCountry('de'), 'de');
    // UN M49 numeric region (es_419) — iTunes would answer HTTP 200 with an
    // error body and no results, silently disabling detection.
    expect(storefrontCountry('419'), isNull);
    expect(storefrontCountry(''), isNull);
    expect(storefrontCountry('USA'), isNull);
    expect(storefrontCountry(null), isNull);
  });

  test('malformed reply shapes → unavailable', () {
    for (final json in <Object?>[
      null,
      'not a map',
      <String, Object?>{},
      {'results': 'not a list'},
      {
        'results': ['not a map'],
      },
      {
        'results': [
          {'trackViewUrl': 'https://apps.apple.com/app/id123'},
        ],
      },
    ]) {
      final d = decideIosStoreUpdate(
        lookupJson: json,
        installedVersion: '1.0.6',
        deviceOsVersion: '18.5',
      );
      expect(d.updateAvailable, isFalse, reason: 'shape: $json');
    }
  });
}
