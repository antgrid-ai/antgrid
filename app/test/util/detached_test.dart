// A rejection inside a detached action must be reported to the log and stop
// there. If it escaped, the test framework's zone would fail this test — which
// is exactly what the app's `PlatformDispatcher.onError` does in production,
// only there it is a fatal crash.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid/util/ab_log.dart';
import 'package:antgrid/util/detached.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String logPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('detached_');
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

  test('an async rejection is logged, not rethrown', () async {
    detached(
      'SUT',
      'thing failed',
      () async => throw TimeoutException('session reply timed out'),
    );
    await Future<void>.delayed(Duration.zero);
    await AbLog.flush();

    final line = readLines().single;
    expect(line['level'], 50);
    expect(line['component'], 'SUT');
    expect(line['msg'], 'thing failed');
    expect(line['error'], contains('session reply timed out'));
  });

  test('a synchronous throw is caught too', () async {
    detached('SUT', 'thing failed', () => throw StateError('sync boom'));
    await Future<void>.delayed(Duration.zero);
    await AbLog.flush();

    expect(readLines().single['error'], contains('sync boom'));
  });

  test('a successful action logs nothing', () async {
    var ran = false;
    detached('SUT', 'thing failed', () async => ran = true);
    await Future<void>.delayed(Duration.zero);
    await AbLog.flush();

    expect(ran, isTrue);
    expect(File(logPath).existsSync() ? readLines() : const [], isEmpty);
  });
}
