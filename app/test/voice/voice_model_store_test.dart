import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid/voice/speech_engine.dart';
import 'package:antgrid/voice/voice_model_catalog.dart';
import 'package:antgrid/voice/voice_model_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _bodies = {
  'encoder.onnx': utf8.encode('encoder-weights' * 100000),
  'decoder.onnx': utf8.encode('decoder'),
  'joiner.onnx': utf8.encode('joiner'),
  'tokens.txt': utf8.encode('a 0\nb 1\n'),
};

VoiceModelFile _file(String name) =>
    VoiceModelFile(name, _bodies[name]!.length, '${sha256.convert(_bodies[name]!)}');

final _model = VoiceModel(
  id: 'test-model',
  label: 'Test model',
  role: VoiceModelRole.offline,
  language: 'en',
  licence: 'test',
  repo: 'org/test',
  revision: 'abc123',
  encoder: _file('encoder.onnx'),
  decoder: _file('decoder.onnx'),
  joiner: _file('joiner.onnx'),
  tokens: _file('tokens.txt'),
);

void main() {
  late Directory root;
  final requests = <http.BaseRequest>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('voice-models');
    requests.clear();
  });
  tearDown(() => root.delete(recursive: true));

  VoiceModelStore store({List<int> Function(String name)? body}) =>
      VoiceModelStore(
        () async => root,
        client: () => MockClient.streaming((request, _) async {
          requests.add(request);
          final name = request.url.pathSegments.last;
          var bytes = body?.call(name) ?? _bodies[name]!;
          final range = request.headers['range'];
          if (range != null) {
            final from = int.parse(range.substring(6, range.length - 1));
            bytes = bytes.sublist(from);
          }
          return http.StreamedResponse(
            Stream.value(bytes),
            range == null ? 200 : 206,
          );
        }),
      );

  test('installs every file at the pinned revision', () async {
    final s = store();
    expect(await s.installed(_model), isFalse);
    final progress = await s.install(_model).toList();
    expect(progress.last, _model.bytes);
    expect(await s.installed(_model), isTrue);
    expect(
      requests.map((r) => r.url.path),
      everyElement(startsWith('/org/test/resolve/abc123/')),
    );
    expect(
      await File('${root.path}/test-model/decoder.onnx').readAsString(),
      'decoder',
    );
    expect(Directory('${root.path}/.partial').existsSync(), isFalse);
  });

  test('a corrupted file is deleted and never installs', () async {
    final s = store(
      body: (name) =>
          name == 'joiner.onnx' ? utf8.encode('joinex') : _bodies[name]!,
    );
    await expectLater(
      s.install(_model).drain<void>(),
      throwsA(isA<SpeechEngineException>()),
    );
    expect(await s.installed(_model), isFalse);
    expect(
      File('${root.path}/.partial/test-model/joiner.onnx').existsSync(),
      isFalse,
    );
    await store().install(_model).drain<void>();
    expect(await store().installed(_model), isTrue);
  });

  test('a partial file resumes with a range request', () async {
    final partial = File('${root.path}/.partial/test-model/encoder.onnx');
    await partial.create(recursive: true);
    await partial.writeAsBytes(_bodies['encoder.onnx']!.sublist(0, 1000));
    await store().install(_model).drain<void>();
    expect(
      requests.firstWhere((r) => r.url.path.endsWith('encoder.onnx')).headers,
      containsPair('range', 'bytes=1000-'),
    );
    expect(await store().installed(_model), isTrue);
  });

  test('cancelling mid-download leaves the model not installed', () async {
    final s = store();
    final done = Completer<void>();
    late StreamSubscription<int> sub;
    sub = s.install(_model).listen((_) {
      if (!done.isCompleted) {
        done.complete();
        unawaited(sub.cancel());
      }
    });
    await done.future;
    await sub.cancel();
    expect(await s.installed(_model), isFalse);
  });

  test('a new revision reads as not installed, and remove deletes', () async {
    final s = store();
    await s.install(_model).drain<void>();
    final bumped = VoiceModel(
      id: _model.id,
      label: _model.label,
      role: _model.role,
      language: _model.language,
      licence: _model.licence,
      repo: _model.repo,
      revision: 'def456',
      encoder: _model.encoder,
      decoder: _model.decoder,
      joiner: _model.joiner,
      tokens: _model.tokens,
    );
    expect(await s.installed(bumped), isFalse);
    await s.remove(_model);
    expect(Directory('${root.path}/test-model').existsSync(), isFalse);
  });

  test('catalog entries are complete and pinned to a commit', () {
    for (final m in voiceModels) {
      expect(m.revision, matches(RegExp(r'^[0-9a-f]{40}$')), reason: m.id);
      for (final f in m.files) {
        expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.name);
        expect(f.bytes, greaterThan(0), reason: f.name);
      }
    }
    expect(voiceModels.map((m) => m.id).toSet(), hasLength(voiceModels.length));
  });
}
