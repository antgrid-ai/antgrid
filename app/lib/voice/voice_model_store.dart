import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'speech_engine.dart';
import 'voice_model_catalog.dart';

/// Debug and release builds share this directory on purpose: the models are
/// immutable per revision, and a second 700 MB copy buys no isolation.
Future<Directory> voiceModelsRoot() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'voice-models'));

/// Installed models live at `<root>/<id>/`; a download assembles in
/// `<root>/.partial/<id>/` and is renamed into place only after every file
/// verifies, so a cancelled or crashed install is never mistaken for a
/// finished one. Partial files are kept so the next attempt resumes.
class VoiceModelStore {
  VoiceModelStore(this._root, {http.Client Function()? client})
    : _client = client ?? http.Client.new;
  final Future<Directory> Function() _root;
  final http.Client Function() _client;

  static const _marker = '.installed';

  /// Progress is reported at this granularity so a 650 MB download does not
  /// rebuild the setup sheet once per socket read.
  static const _progressStep = 1 << 20;

  Future<Directory> dir(VoiceModel model) async =>
      Directory(p.join((await _root()).path, model.id));

  Future<bool> installed(VoiceModel model) async {
    final marker = File(p.join((await dir(model)).path, _marker));
    // The marker holds the revision, so a catalog bump reads as not installed
    // instead of loading files the new entry no longer describes.
    return await marker.exists() &&
        await marker.readAsString() == model.revision;
  }

  /// Yields the bytes of [model] present so far, from what earlier attempts
  /// left behind up to [VoiceModel.bytes].
  Stream<int> install(VoiceModel model) async* {
    final root = await _root();
    final staging = Directory(p.join(root.path, '.partial', model.id));
    await staging.create(recursive: true);
    final client = _client();
    try {
      var done = 0;
      var reported = -_progressStep;
      for (final f in model.files) {
        final file = File(p.join(staging.path, f.name));
        var have = await file.exists() ? await file.length() : 0;
        if (have > f.bytes) {
          await file.delete();
          have = 0;
        }
        done += have;
        if (have < f.bytes) {
          final request = http.Request('GET', model.url(f));
          if (have > 0) request.headers['range'] = 'bytes=$have-';
          final response = await client.send(request);
          if (response.statusCode == 200 && have > 0) {
            done -= have;
            have = 0;
          } else if (response.statusCode != 200 &&
              response.statusCode != 206) {
            throw SpeechEngineException(
              'Could not download ${model.label} '
              '(HTTP ${response.statusCode}). Retry setup.',
            );
          }
          final sink = file.openWrite(
            mode: have > 0 ? FileMode.append : FileMode.write,
          );
          try {
            await for (final chunk in response.stream) {
              sink.add(chunk);
              done += chunk.length;
              if (done - reported >= _progressStep) {
                reported = done;
                yield done;
              }
            }
          } finally {
            await sink.close();
          }
        }
        if (!await _verify(file, f)) {
          await file.delete();
          throw SpeechEngineException(
            '${model.label} failed its integrity check and was deleted. '
            'Retry setup.',
          );
        }
      }
      yield done;
      await File(p.join(staging.path, _marker)).writeAsString(model.revision);
      final target = await dir(model);
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      final parent = staging.parent;
      if (await parent.list().isEmpty) await parent.delete();
    } on SocketException {
      throw _interrupted(model);
    } on http.ClientException {
      throw _interrupted(model);
    } on FileSystemException catch (error) {
      throw SpeechEngineException(
        'Could not save ${model.label}: ${error.osError?.message ?? error.message}. '
        'Check free disk space, then retry setup.',
      );
    } finally {
      client.close();
    }
  }

  Future<void> remove(VoiceModel model) async {
    final root = await _root();
    for (final d in [
      await dir(model),
      Directory(p.join(root.path, '.partial', model.id)),
    ]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  }

  SpeechEngineException _interrupted(VoiceModel model) =>
      SpeechEngineException(
        'Download of ${model.label} was interrupted. Retry setup to resume.',
      );

  /// Hashing the largest encoder takes seconds, so it runs off the UI isolate.
  static Future<bool> _verify(File file, VoiceModelFile expected) async {
    if (await file.length() != expected.bytes) return false;
    final path = file.path;
    final digest = await Isolate.run(
      () async => (await sha256.bind(File(path).openRead()).first).toString(),
    );
    return digest == expected.sha256;
  }
}
