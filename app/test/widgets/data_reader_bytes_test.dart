// The completion contract behind every `DataReader.getFile` in the app. Only
// one of its three endings calls `onFile`, and a completer left hanging on
// either of the others wedges the gesture that started it — a paste or a drop
// that never resolves and never says why.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/widgets/data_reader_bytes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completes with the bytes the read hands back', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final read = collectFileBytes((onFile, onError) {
      onFile(() async => bytes);
      return true;
    });
    expect(await read, same(bytes));
  });

  test('completes null when the platform never starts the read', () async {
    // `getFile` returned no ReadProgress: the format vanished between
    // `canProvide` and the read, and the callback will never run.
    var calledBack = false;
    final read = collectFileBytes((onFile, onError) {
      calledBack = true;
      return false;
    });
    expect(await read, isNull);
    expect(calledBack, isTrue);
  });

  test('rejects when the platform reports an error instead', () async {
    final read = collectFileBytes((onFile, onError) {
      onError(StateError('no adapter'));
      return true;
    });
    await expectLater(read, throwsStateError);
  });

  test('rejects when the read itself throws', () async {
    final read = collectFileBytes((onFile, onError) {
      onFile(() async => throw StateError('stream died'));
      return true;
    });
    await expectLater(read, throwsStateError);
  });

  test('the callback swallows its own failure rather than rejecting', () async {
    // super_clipboard DISCARDS the future this callback returns on its
    // in-memory path, so a rejection here would reach the zone unhandled —
    // fatal, per util/detached.dart.
    Future<void>? returned;
    final read = collectFileBytes((onFile, onError) {
      returned = onFile(() async => throw StateError('stream died'));
      return true;
    });
    await expectLater(returned, completes);
    await expectLater(read, throwsStateError);
  });

  test('a second ending cannot re-complete a settled future', () async {
    late void Function(Object) reportError;
    final read = collectFileBytes((onFile, onError) {
      reportError = onError;
      onFile(() async => Uint8List.fromList([7]));
      return true;
    });
    expect(await read, [7]);
    // super_clipboard is free to report an error after the read already
    // handed its bytes over, and completing a settled completer throws.
    expect(() => reportError(StateError('late')), returnsNormally);
  });

  test('an error racing an in-flight read wins, and is reported', () async {
    // The other order: the platform gives up while the read is still pending.
    // Whoever lands first settles it — what matters is that the caller is told
    // something rather than left waiting on bytes that are never coming.
    final gate = Completer<Uint8List>();
    final read = collectFileBytes((onFile, onError) {
      onFile(() => gate.future);
      onError(StateError('adapter closed'));
      return true;
    });
    await expectLater(read, throwsStateError);
    gate.complete(Uint8List.fromList([7]));
  });
}
