import 'dart:io';

import 'package:antgrid/util/log_rotation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ab_rot_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('leaves a small file untouched', () {
    final p = '${tmp.path}/a.log';
    File(p).writeAsStringSync('small');
    rotateLogIfNeeded(p, maxBytes: 1024);
    expect(File(p).existsSync(), isTrue);
    expect(File('$p.old').existsSync(), isFalse);
  });

  test('rotates a file past the cap to .old', () {
    final p = '${tmp.path}/a.log';
    File(p).writeAsStringSync('X' * 2048);
    rotateLogIfNeeded(p, maxBytes: 1024);
    expect(File(p).existsSync(), isFalse);
    expect(File('$p.old').readAsStringSync().length, 2048);
  });

  test('overwrites an existing .old (single generation)', () {
    final p = '${tmp.path}/a.log';
    File('$p.old').writeAsStringSync('previous');
    File(p).writeAsStringSync('Y' * 2048);
    rotateLogIfNeeded(p, maxBytes: 1024);
    expect(File('$p.old').readAsStringSync(), 'Y' * 2048);
  });

  test('is a no-op when the file is missing', () {
    final p = '${tmp.path}/missing.log';
    rotateLogIfNeeded(p, maxBytes: 1024);
    expect(File(p).existsSync(), isFalse);
    expect(File('$p.old').existsSync(), isFalse);
  });
}
