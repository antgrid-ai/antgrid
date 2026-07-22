import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

({int width, int height}) _pngSize(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('Expected PNG asset to exist: $path');
  }

  final bytes = Uint8List.fromList(file.readAsBytesSync());
  if (bytes.length < 24) {
    fail('PNG asset is too short to contain an IHDR chunk: $path');
  }

  final data = ByteData.sublistView(bytes);
  return (width: data.getUint32(16), height: data.getUint32(20));
}

void main() {
  const sourcePath = 'assets/icon/android12-splash-wordmark.png';

  test('Android 12 splash uses its square safe-zone asset', () {
    final pubspec = File(
      'pubspec.yaml',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      pubspec,
      contains('android_12:\n    color: "#08090A"\n    image: "$sourcePath"'),
    );
    expect(_pngSize(sourcePath), (width: 1152, height: 1152));
  });

  test('generated Android 12 mdpi drawable remains square', () {
    expect(
      _pngSize('android/app/src/main/res/drawable-mdpi/android12splash.png'),
      (width: 288, height: 288),
    );
  });
}
