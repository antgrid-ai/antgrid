// app/test/launcher/host_discovery_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_discovery.dart';

void main() {
  group('HostFile.tryParse', () {
    test('parses a valid host.json', () {
      const json =
          '{"version":1,"pid":4242,"controlPort":51234,'
          '"token":"abc","startedAt":"2026-06-11T00:00:00.000Z",'
          '"agentVersion":"0.1.0"}';
      final h = HostFile.tryParse(json);
      expect(h, isNotNull);
      expect(h!.pid, 4242);
      expect(h.controlPort, 51234);
      expect(h.token, 'abc');
    });

    test('rejects wrong version', () {
      const json =
          '{"version":2,"pid":1,"controlPort":1,"token":"t",'
          '"startedAt":"x","agentVersion":"v"}';
      expect(HostFile.tryParse(json), isNull);
    });

    test('rejects malformed json', () {
      expect(HostFile.tryParse('not json'), isNull);
    });

    test('rejects missing fields', () {
      expect(HostFile.tryParse('{"version":1,"pid":1}'), isNull);
    });
  });

  group('readHostFile', () {
    test('returns null when the file is absent', () async {
      final dir = await Directory.systemTemp.createTemp('ab-host-');
      addTearDown(() => dir.delete(recursive: true));
      expect(await readHostFile('${dir.path}/host.json'), isNull);
    });

    test('round-trips a written file', () async {
      final dir = await Directory.systemTemp.createTemp('ab-host-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/host.json';
      await File(path).writeAsString(
        '{"version":1,"pid":7,"controlPort":9999,'
        '"token":"tok","startedAt":"s","agentVersion":"v"}',
      );
      final h = await readHostFile(path);
      expect(h!.controlPort, 9999);
      expect(h.token, 'tok');
    });
  });

  group('hostFilePath / hostDir', () {
    test('honors ANTGRID_DIR when provided', () {
      expect(hostDir(abDir: '/tmp/customab'), '/tmp/customab');
      expect(hostFilePath(abDir: '/tmp/customab'), '/tmp/customab/host.json');
    });
  });
}
