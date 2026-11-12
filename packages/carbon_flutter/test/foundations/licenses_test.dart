import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = Uint8List.fromList('licence text for $key'.codeUnits);
    return ByteData.sublistView(bytes);
  }
}

Future<List<LicenseEntry>> _entries() async {
  final list = <LicenseEntry>[];
  await for (final e in LicenseRegistry.licenses) {
    list.add(e);
  }
  return list;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('register adds the font and icon notices once', () async {
    CarbonLicenses.debugResetForTesting();
    final before = (await _entries()).length;
    final bundle = _FakeBundle();

    CarbonLicenses.register(bundle: bundle);
    CarbonLicenses.register(bundle: bundle);

    final added = (await _entries()).skip(before).toList();
    expect(added, hasLength(2));
    expect(added.first.packages, containsAll(['IBM Plex Sans', 'IBM Plex Mono']));
    expect(added.last.packages.single, contains('Carbon icons'));
    String text(LicenseEntry e) => e.paragraphs.map((p) => p.text).join(' ');
    expect(text(added.first), contains(CarbonLicenses.fontsAsset));
    expect(text(added.last), contains(CarbonLicenses.iconsAsset));

    CarbonLicenses.register(bundle: bundle);
    expect((await _entries()).length, before + 2);
  });
}
