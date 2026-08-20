import 'dart:async';
import 'dart:typed_data';

/// Starts one `DataReader.getFile` and reports whether it actually began.
///
/// [onFile] is handed the read itself rather than the file, so a caller can cap
/// or transform the bytes; it must be AWAITED by the platform callback, because
/// the adapter closes a virtual file as soon as that callback's future settles.
/// Returning false stands for `getFile`'s null [ReadProgress].
typedef FileRead =
    bool Function(
      Future<void> Function(Future<Uint8List> Function() read) onFile,
      void Function(Object error) onError,
    );

/// Bridges `DataReader.getFile`'s callback shape to a future.
///
/// Three paths reach here and only one of them calls `onFile`: a null
/// [ReadProgress] means the format vanished between `canProvide` and the read,
/// `onError` fires instead on a platform failure, and the read itself can
/// throw. A completer left hanging on any of them would wedge the gesture with
/// no error to show for it, so all three complete it. The callback also
/// swallows its own failure rather than returning a rejected future:
/// super_clipboard discards the future the callback returns on its in-memory
/// path, so a rejection there reaches the zone unhandled.
///
/// Shared by the paste and drop gestures so they cannot end differently.
Future<Uint8List?> collectFileBytes(FileRead start) {
  final completer = Completer<Uint8List?>();
  void succeed(Uint8List? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }

  final started = start((read) async {
    try {
      succeed(await read());
    } catch (error) {
      fail(error);
    }
  }, fail);
  if (!started) succeed(null);
  return completer.future;
}
