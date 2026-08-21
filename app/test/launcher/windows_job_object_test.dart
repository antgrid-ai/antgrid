// app/test/launcher/windows_job_object_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/windows_job_object.dart';

void main() {
  test('no-op off Windows', () {
    expect(encloseInAppLifetimeJob(pid), isFalse);
  }, skip: Platform.isWindows ? 'Windows takes the real path below' : false);

  group('Windows', () {
    // The struct is hand-written against the Win32 headers; SetInformationJobObject
    // validates the length against the info class, so a drifted layout fails at
    // runtime with nothing but a swallowed warning. 144 = 64-byte basic limits +
    // 48-byte IO_COUNTERS + four SIZE_T.
    test('JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on x64', () {
      expect(jobExtendedLimitInformationSize, 144);
    });

    test('encloses a live process — job creation and assignment both succeed', () async {
      // A child that outlives the call; the assertion is that we can enclose it,
      // not that it dies (killing the job is the kernel's job at process exit,
      // which a test process cannot observe about itself).
      final proc = await Process.start('cmd.exe', [
        '/c',
        'ping',
        '127.0.0.1',
        '-n',
        '30',
      ]);
      addTearDown(() => Process.run('taskkill', ['/F', '/T', '/PID', '${proc.pid}']));
      expect(encloseInAppLifetimeJob(proc.pid), isTrue);
    });

    test('a dead pid fails soft rather than throwing', () async {
      final proc = await Process.start('cmd.exe', ['/c', 'exit', '0']);
      await proc.exitCode;
      expect(encloseInAppLifetimeJob(proc.pid), isFalse);
    });
  }, skip: Platform.isWindows ? false : 'Windows-only');
}
