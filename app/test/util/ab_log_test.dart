import 'dart:convert';
import 'dart:io';

import 'package:antgrid/util/ab_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Poison {
  @override
  String toString() => throw StateError('boom');
}

void main() {
  late Directory tmp;
  late String logPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ab_log_');
    logPath = '${tmp.path}/app.log';
    AbLog.configureForTest(logPath);
  });
  tearDown(() {
    AbLog.dispose();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, dynamic>> readLines() => File(logPath)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();

  test('writes one pino-shaped JSON line with flat fields', () async {
    AbLog.info('HostController', 'attached', fields: {'projectId': 'abc'});
    await AbLog.flush();
    final lines = readLines();
    expect(lines.length, 1);
    final o = lines.single;
    expect(o['level'], 30);
    expect(o['time'], isA<int>());
    expect(o['pid'], isA<int>());
    expect(o['component'], 'HostController');
    expect(o['msg'], 'attached');
    expect(o['projectId'], 'abc');
  });

  test('maps each method to its numeric level', () async {
    AbLog.debug('C', 'd');
    AbLog.info('C', 'i');
    AbLog.warn('C', 'w');
    AbLog.error('C', 'e');
    await AbLog.flush();
    expect(readLines().map((o) => o['level']).toList(), [20, 30, 40, 50]);
  });

  test('rotates app.log past the cap before writing', () async {
    File(logPath).writeAsStringSync('X' * (10 * 1024 * 1024 + 1));
    AbLog.info('C', 'after-rotate');
    await AbLog.flush();
    expect(File('$logPath.old').existsSync(), isTrue);
    final lines = readLines();
    expect(lines.length, 1);
    expect(lines.single['msg'], 'after-rotate');
  });

  test('mirrors to debugPrint only when enabled', () async {
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => captured.add(m ?? '');
    try {
      AbLog.configureForTest(logPath, mirror: true);
      AbLog.info('C', 'hi');
      await AbLog.flush();
      expect(captured, contains('[C] hi'));

      captured.clear();
      AbLog.configureForTest(logPath, mirror: false);
      AbLog.info('C', 'quiet');
      await AbLog.flush();
      expect(captured, isEmpty);
    } finally {
      debugPrint = original;
    }
  });

  test('never throws on a bad field value', () async {
    AbLog.error('C', 'boom', fields: {'bad': Object()});
    await AbLog.flush();
    final o = readLines().single;
    expect(o['msg'], 'boom');
    expect(o['level'], 50);
  });

  test('never throws even when a field toString() throws', () async {
    AbLog.error('C', 'survived', fields: {'poison': _Poison()});
    await AbLog.flush();
    final o = readLines().single;
    expect(o['msg'], 'survived');
    expect(o['level'], 50);
  });

  test('creates the parent directory when it does not exist yet', () async {
    // Clean-install case: hostDir() may not exist, and writeAsString won't
    // create missing parents — the write would fail-open and drop every line.
    final nested = '${tmp.path}/does/not/exist/app.log';
    AbLog.configureForTest(nested);
    AbLog.info('C', 'created');
    await AbLog.flush();
    final lines = File(nested)
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(lines.single['msg'], 'created');
  });

  test('flush drains every line past the eager-flush threshold', () async {
    for (var i = 0; i < 200; i++) {
      AbLog.info('C', 'm$i');
    }
    await AbLog.flush();
    expect(readLines().length, 200);
  });
}
