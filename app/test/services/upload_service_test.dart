import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/upload_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> makeSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  test(
    'upload sends start, per-chunk with ack pacing, done; returns path',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final svc = UploadService.fromSession(session);

      // 1.5 chunks worth of data → exactly 2 chunks.
      final bytes = Uint8List.fromList(
        List<int>.generate(UploadService.kChunkBytes + 100, (i) => i % 251),
      );
      final progress = <int>[];
      final future = svc.upload(
        fileName: 'data.bin',
        bytes: bytes,
        onProgress: (sent, total) => progress.add(sent),
      );
      await Future<void>.delayed(Duration.zero);

      final start = t.sent.firstWhere((m) => m['type'] == 'file:upload-start');
      expect(start['fileName'], 'data.bin');
      expect(start['size'], bytes.length);
      final requestId = start['requestId'] as String;

      t.emit('file:upload-ready', {'requestId': requestId, 'uploadId': 'u1'});
      await Future<void>.delayed(Duration.zero);

      // Chunk 0 must be sent; chunk 1 must NOT be in flight before ack 0.
      var chunks = t.sent
          .where((m) => m['type'] == 'file:upload-chunk')
          .toList();
      expect(chunks.length, 1);
      expect(chunks[0]['seq'], 0);
      expect(
        base64Decode(chunks[0]['data'] as String).length,
        UploadService.kChunkBytes,
      );

      t.emit('file:upload-ack', {'uploadId': 'u1', 'seq': 0});
      await Future<void>.delayed(Duration.zero);
      chunks = t.sent.where((m) => m['type'] == 'file:upload-chunk').toList();
      expect(chunks.length, 2);
      expect(chunks[1]['seq'], 1);

      t.emit('file:upload-ack', {'uploadId': 'u1', 'seq': 1});
      await Future<void>.delayed(Duration.zero);
      expect(t.sent.any((m) => m['type'] == 'file:upload-done'), isTrue);

      t.emit('file:upload-result', {
        'requestId': requestId,
        'uploadId': 'u1',
        'ok': true,
        'path': '/proj/.antgrid/uploads/u1-data.bin',
      });

      expect(await future, '/proj/.antgrid/uploads/u1-data.bin');
      expect(progress.last, bytes.length);

      await svc.dispose();
      await session.close();
    },
  );

  test('rejects over-cap files before sending anything', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final bytes = Uint8List(UploadService.kMaxUploadBytes + 1);
    await expectLater(
      svc.upload(fileName: 'big.bin', bytes: bytes),
      throwsA(
        isA<UploadException>().having((e) => e.code, 'code', 'TOO_LARGE'),
      ),
    );
    expect(t.sent.where((m) => m['type'] == 'file:upload-start'), isEmpty);

    await svc.dispose();
    await session.close();
  });

  test('bridge error result fails the upload with its code', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(4));
    await Future<void>.delayed(Duration.zero);
    final requestId =
        t.sent.firstWhere((m) => m['type'] == 'file:upload-start')['requestId']
            as String;

    t.emit('file:upload-result', {
      'requestId': requestId,
      'ok': false,
      'error': 'BUSY',
      'message': 'Too many concurrent uploads',
    });

    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'BUSY')),
    );

    await svc.dispose();
    await session.close();
  });

  test('mid-transfer error result fails a pending chunk ack', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(8));
    await Future<void>.delayed(Duration.zero);
    final requestId =
        t.sent.firstWhere((m) => m['type'] == 'file:upload-start')['requestId']
            as String;
    t.emit('file:upload-ready', {'requestId': requestId, 'uploadId': 'u1'});
    await Future<void>.delayed(Duration.zero);

    // App is now awaiting ack for chunk 0; the bridge aborts instead.
    t.emit('file:upload-result', {
      'requestId': requestId,
      'uploadId': 'u1',
      'ok': false,
      'error': 'TIMEOUT',
      'message': 'Upload timed out',
    });

    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'TIMEOUT')),
    );

    await svc.dispose();
    await session.close();
  });

  test('uploadErrorText maps codes to user copy', () {
    expect(
      uploadErrorText(const UploadException('TOO_LARGE', ''), 'a.bin'),
      contains('20 MB'),
    );
    expect(
      uploadErrorText(const UploadException('TIMEOUT', ''), 'a.bin'),
      contains('timed out'),
    );
    expect(uploadErrorText(Exception('x'), 'a.bin'), contains('a.bin'));
  });
}
