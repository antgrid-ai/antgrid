import 'package:antgrid/update/macos_appcast_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The exact document build-desktop.yml's appcast step emits, so a change to
/// that generator that this parser can't read fails here.
String _appcast({required String build, required String shortVersion}) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>Antgrid</title>
<item>
<title>Antgrid v$shortVersion</title>
<sparkle:version>$build</sparkle:version>
<sparkle:shortVersionString>$shortVersion</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>10.15</sparkle:minimumSystemVersion>
<sparkle:releaseNotesLink>https://example.invalid/notes</sparkle:releaseNotesLink>
<enclosure url="https://example.invalid/antgrid-macos.dmg" length="1" type="application/octet-stream"/>
</item>
</channel>
</rss>
''';

MacosAppcastUpdateService _serviceReturning(
  String body, {
  int status = 200,
}) => MacosAppcastUpdateService(
  httpClient: MockClient((_) async => http.Response(body, status)),
);

void main() {
  setUp(() {
    // CFBundleVersion 40 — CI stamps it from the workflow run counter.
    PackageInfo.setMockInitialValues(
      appName: 'antgrid',
      packageName: 'ai.radhaai.antgrid',
      version: '1.20662.40',
      buildNumber: '40',
      buildSignature: '',
    );
  });

  group('isNewerBuild', () {
    test('a higher appcast build wins', () {
      expect(isNewerBuild(currentBuild: '40', appcastBuild: '41'), isTrue);
    });

    test('the same build is not an update', () {
      expect(isNewerBuild(currentBuild: '40', appcastBuild: '40'), isFalse);
    });

    test('an older build is not an update', () {
      expect(isNewerBuild(currentBuild: '40', appcastBuild: '39'), isFalse);
    });

    test('surrounding whitespace is tolerated', () {
      expect(isNewerBuild(currentBuild: ' 40 ', appcastBuild: '\n41\n'), isTrue);
    });

    test('unparseable input never lights the row', () {
      expect(isNewerBuild(currentBuild: '40', appcastBuild: 'v1.2'), isFalse);
      expect(isNewerBuild(currentBuild: 'dev', appcastBuild: '41'), isFalse);
      expect(isNewerBuild(currentBuild: '', appcastBuild: ''), isFalse);
    });
  });

  group('MacosAppcastUpdateService', () {
    test('newer advertised build → true', () async {
      final s = _serviceReturning(
        _appcast(build: '41', shortVersion: '1.20662.41'),
      );
      expect(await s.isUpdateAvailable(), isTrue);
    });

    test('same build → false', () async {
      final s = _serviceReturning(
        _appcast(build: '40', shortVersion: '1.20662.40'),
      );
      expect(await s.isUpdateAvailable(), isFalse);
    });

    // The failure this whole service exists to prevent: no appcast published
    // must leave the row dark, not light it against a feed Sparkle can't read.
    test('404 (no appcast published) → false', () async {
      final s = _serviceReturning('Not Found', status: 404);
      expect(await s.isUpdateAvailable(), isFalse);
    });

    test('malformed XML → false', () async {
      final s = _serviceReturning('<rss><channel><item>');
      expect(await s.isUpdateAvailable(), isFalse);
    });

    test('no <item> → false', () async {
      final s = _serviceReturning(
        '<?xml version="1.0"?><rss><channel><title>Antgrid</title></channel></rss>',
      );
      expect(await s.isUpdateAvailable(), isFalse);
    });

    test('item without sparkle:version → false', () async {
      final s = _serviceReturning(
        '<?xml version="1.0"?><rss><channel><item><title>x</title></item></channel></rss>',
      );
      expect(await s.isUpdateAvailable(), isFalse);
    });

    test('network failure → false', () async {
      final s = MacosAppcastUpdateService(
        httpClient: MockClient((_) async => throw const SocketishError()),
      );
      expect(await s.isUpdateAvailable(), isFalse);
    });

    // A feed carrying history must be read at its newest entry only; a
    // document-wide search would find the older item and go dark.
    test('reads the FIRST item, not a later one', () async {
      const feed = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<item><sparkle:version>41</sparkle:version></item>
<item><sparkle:version>39</sparkle:version></item>
</channel>
</rss>
''';
      expect(await _serviceReturning(feed).isUpdateAvailable(), isTrue);
    });
  });
}

/// Stands in for a transport failure without depending on dart:io types.
class SocketishError implements Exception {
  const SocketishError();
}
