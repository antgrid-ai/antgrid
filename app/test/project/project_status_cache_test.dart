import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';

void main() {
  group('ProjectStatusCache', () {
    late Directory tmp;
    late ProjectStatusCache cache;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('antgrid-status-cache-test-');
      cache = ProjectStatusCache.testInstance(root: tmp.path);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('write + read round-trip', () async {
      final status = const ProjectStatus.empty().copyWith(
        configError: true,
        configErrorMessage: 'boom',
      );
      await cache.write('p1', status);
      final read = await cache.read('p1');
      expect(read, isNotNull);
      expect(read!.configError, true);
      expect(read.configErrorMessage, 'boom');
    });

    test('read returns null for unknown projectId', () async {
      expect(await cache.read('unknown'), isNull);
    });

    test('read returns null for corrupt file (does not throw)', () async {
      final f = File(p.join(tmp.path, 'cache', 'project-status', 'p2.json'));
      await f.create(recursive: true);
      await f.writeAsString('{not json');
      expect(await cache.read('p2'), isNull);
    });

    test(
      'write is atomic — interrupted write leaves prior value readable',
      () async {
        final first = const ProjectStatus.empty().copyWith(
          configErrorMessage: 'first',
        );
        await cache.write('p3', first);

        final second = const ProjectStatus.empty().copyWith(
          configErrorMessage: 'second',
        );
        // ignore: unawaited_futures
        cache.write('p3', second);

        final mid = await cache.read('p3');
        expect(mid, isNotNull);
        expect(['first', 'second'], contains(mid!.configErrorMessage));
      },
    );

    test('clear removes the projectId file', () async {
      await cache.write('p4', const ProjectStatus.empty());
      await cache.clear('p4');
      expect(await cache.read('p4'), isNull);
    });
  });
}
