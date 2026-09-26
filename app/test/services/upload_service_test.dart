import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
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
    'upload opens one exchange with the file and returns the bridge\'s '
    'staged path',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final svc = UploadService.fromSession(session);

      final bytes = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
      final progress = <int>[];
      final future = svc.upload(
        fileName: 'data.bin',
        bytes: bytes,
        onProgress: (sent, total) => progress.add(sent),
      );
      await Future<void>.delayed(Duration.zero);

      expect(t.uploadCalls, hasLength(1));
      final exchange = t.uploadCalls.single;
      expect(exchange.fileName, 'data.bin');
      expect(exchange.bytes, bytes);
      expect(exchange.checkoutId, 'main');

      exchange.progress(bytes.length, bytes.length);

      exchange.complete(
        const UploadStreamResult(
          ok: true,
          uploadId: 'u1',
          path: '/proj/.antgrid/uploads/u1-data.bin',
          relPath: '.antgrid/uploads/u1-data.bin',
        ),
      );

      final result = await future;
      expect(result.path, '/proj/.antgrid/uploads/u1-data.bin');
      expect(result.relPath, '.antgrid/uploads/u1-data.bin');
      // No mimeType in the result: the bridge has no viewer for a .bin, which
      // is what withholds the preview affordance.
      expect(result.mimeType, isNull);
      expect(result.isPreviewable, isFalse);
      expect(progress, [bytes.length]);

      await svc.dispose();
      await session.close();
    },
  );

  test('rejects over-cap files before opening an exchange', () async {
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
    expect(t.uploadCalls, isEmpty);

    await svc.dispose();
    await session.close();
  });

  test('a bridge ok:false result fails the upload with its code', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(4));
    await Future<void>.delayed(Duration.zero);
    final exchange = t.uploadCalls.single;

    exchange.complete(
      const UploadStreamResult(
        ok: false,
        error: 'BUSY',
        message: 'Too many concurrent uploads',
      ),
    );

    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'BUSY')),
    );

    await svc.dispose();
    await session.close();
  });

  test('an UploadFailure(TIMEOUT) from the exchange passes through', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(8));
    await Future<void>.delayed(Duration.zero);
    final exchange = t.uploadCalls.single;

    exchange.fail(const UploadFailure('TIMEOUT'));

    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'TIMEOUT')),
    );

    await svc.dispose();
    await session.close();
  });

  test('a CAP_EXCEEDED refusal maps to BUSY', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(8));
    await Future<void>.delayed(Duration.zero);
    final exchange = t.uploadCalls.single;

    exchange.fail(
      const UploadFailure('REFUSED', refusedCode: StreamRefusedCode.capExceeded),
    );

    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'BUSY')),
    );

    await svc.dispose();
    await session.close();
  });

  test('every other refusal reason maps to OFFLINE', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(8));
    await Future<void>.delayed(Duration.zero);
    final exchange = t.uploadCalls.single;

    exchange.fail(
      const UploadFailure('REFUSED', refusedCode: StreamRefusedCode.notAllowed),
    );

    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'OFFLINE')),
    );

    await svc.dispose();
    await session.close();
  });

  test('cancelling the token cancels the exchange', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final token = UploadCancelToken();
    final future = svc.upload(
      fileName: 'x.bin',
      bytes: Uint8List(8),
      cancelToken: token,
    );
    await Future<void>.delayed(Duration.zero);
    final exchange = t.uploadCalls.single;

    token.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(exchange.cancelled, isTrue);

    exchange.fail(const UploadFailure('CANCELLED'));
    await expectLater(
      future,
      throwsA(
        isA<UploadException>().having((e) => e.code, 'code', 'CANCELLED'),
      ),
    );

    await svc.dispose();
    await session.close();
  });

  test('dispose cancels every in-flight upload and fails it OFFLINE', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final svc = UploadService.fromSession(session);

    final future = svc.upload(fileName: 'x.bin', bytes: Uint8List(8));
    future.ignore();
    await Future<void>.delayed(Duration.zero);
    final exchange = t.uploadCalls.single;

    await svc.dispose();
    expect(exchange.cancelled, isTrue);
    // What a real exchange does once cancel() lands.
    exchange.fail(const UploadFailure('CANCELLED'));
    await expectLater(
      future,
      throwsA(isA<UploadException>().having((e) => e.code, 'code', 'OFFLINE')),
    );

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
