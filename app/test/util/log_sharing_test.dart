import 'dart:io';

import 'package:antgrid/util/log_sharing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory tmp;
  late String current;
  late String old;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('log_share_');
    current = '${tmp.path}/app.log';
    old = '${tmp.path}/app.log.old';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const shared = ShareResult('x', ShareResultStatus.success);

  test('flushes AbLog before sharing, oldest generation first', () async {
    File(old).writeAsStringSync('older\n');
    File(current).writeAsStringSync('newer\n');
    final calls = <String>[];
    ShareParams? params;
    const origin = Rect.fromLTWH(1, 2, 3, 4);

    final outcome = await shareAppLogs(
      origin: origin,
      logDir: tmp.path,
      flush: () async => calls.add('flush'),
      share: (p) async {
        calls.add('share');
        params = p;
        return shared;
      },
    );

    expect(calls, ['flush', 'share']);
    expect(params!.files!.map((f) => f.path), [old, current]);
    expect(params!.sharePositionOrigin, origin);
    expect(outcome, LogShareOutcome.presented);
  });

  test('shares app.log alone when nothing has rotated', () async {
    File(current).writeAsStringSync('only\n');
    ShareParams? params;
    await shareAppLogs(
      logDir: tmp.path,
      flush: () async {},
      share: (p) async {
        params = p;
        return shared;
      },
    );
    expect(params!.files!.map((f) => f.path), [current]);
  });

  test('an empty or missing log is noLogFiles and opens no sheet', () async {
    var shareCalls = 0;
    Future<ShareResult> share(ShareParams p) async {
      shareCalls++;
      return shared;
    }

    File(current).writeAsStringSync('');
    expect(
      await shareAppLogs(logDir: tmp.path, flush: () async {}, share: share),
      LogShareOutcome.noLogFiles,
    );

    File(current).deleteSync();
    expect(
      await shareAppLogs(logDir: tmp.path, flush: () async {}, share: share),
      LogShareOutcome.noLogFiles,
    );
    expect(shareCalls, 0);
  });

  test('a dismissed sheet is not a failure', () async {
    File(current).writeAsStringSync('x\n');
    final outcome = await shareAppLogs(
      logDir: tmp.path,
      flush: () async {},
      share: (_) async => const ShareResult('', ShareResultStatus.dismissed),
    );
    expect(outcome, LogShareOutcome.presented);
  });

  test('a throwing share is reported, never thrown', () async {
    File(current).writeAsStringSync('x\n');
    final outcome = await shareAppLogs(
      logDir: tmp.path,
      flush: () async {},
      share: (_) async => throw PlatformException(code: 'x'),
    );
    expect(outcome, LogShareOutcome.failed);
  });

  test('shareableLogFiles skips missing generations', () {
    expect(shareableLogFiles(tmp.path), isEmpty);
    File(old).writeAsStringSync('o');
    expect(shareableLogFiles(tmp.path), [old]);
    File(current).writeAsStringSync('c');
    expect(shareableLogFiles(tmp.path), [old, current]);
  });

  test("the push isolate's log and its rotation are shared too", () {
    final push = '${tmp.path}/app-push.log';
    File(current).writeAsStringSync('c');
    File(push).writeAsStringSync('p');
    File('$push.old').writeAsStringSync('po');
    expect(shareableLogFiles(tmp.path), ['$push.old', push, current]);
  });
}
