import 'package:fleather/fleather.dart';

import '../../../services/clipboard_image_reader.dart';

/// How long to wait before retrying a paste that came back with neither an
/// image nor text — long enough to dodge the race where Windows' clipboard
/// history flyout (Win+V) is still writing the picked entry onto the system
/// clipboard when the first read runs (a known Flutter/Windows 11 issue,
/// flutter/flutter#143997, where a Win+V paste can land as nothing at all),
/// short enough that a genuinely empty clipboard doesn't feel sluggish.
const kEmptyPasteRetryDelay = Duration(milliseconds: 150);

/// Resolves one paste into either an attachment or document text.
///
/// A null return tells Fleather to insert nothing — which is what routes an
/// image to the attachment strip instead of into the prompt body.
///
/// An image wins over text the same clipboard also carries: a source that
/// offers both (a browser, a spreadsheet) is offering one picture, and its
/// text is that picture's markup rather than what the user meant to paste.
///
/// A first pass that finds neither is retried once after [retryDelay] before
/// giving up — see [kEmptyPasteRetryDelay]. A real empty clipboard just pays
/// that one extra round-trip; a successful image or text read never does.
Future<FleatherClipboardData?> resolveComposerPaste({
  required ClipboardImageReader readImage,
  required void Function(PastedImage) onImagePasted,
  required Future<FleatherClipboardData?> Function() readText,
  void Function(Object error, StackTrace stack)? onImageReadError,
  Duration retryDelay = kEmptyPasteRetryDelay,
}) async {
  final first = await _tryOnce(
    readImage: readImage,
    onImagePasted: onImagePasted,
    readText: readText,
    onImageReadError: onImageReadError,
  );
  if (first.handled) return first.data;
  await Future<void>.delayed(retryDelay);
  final second = await _tryOnce(
    readImage: readImage,
    onImagePasted: onImagePasted,
    readText: readText,
    onImageReadError: onImageReadError,
  );
  return second.data;
}

/// One attempt. [_PasteAttempt.handled] is true once an image was attached
/// (data is then always null — "insert nothing") or text came back
/// non-empty; false means the caller should retry.
Future<_PasteAttempt> _tryOnce({
  required ClipboardImageReader readImage,
  required void Function(PastedImage) onImagePasted,
  required Future<FleatherClipboardData?> Function() readText,
  void Function(Object error, StackTrace stack)? onImageReadError,
}) async {
  try {
    final image = await readImage();
    if (image != null) {
      onImagePasted(image);
      return const _PasteAttempt(handled: true, data: null);
    }
  } catch (error, stack) {
    // A clipboard probe must never break paste — fall through to text.
    onImageReadError?.call(error, stack);
  }
  final text = await readText();
  return _PasteAttempt(handled: text != null && !text.isEmpty, data: text);
}

class _PasteAttempt {
  const _PasteAttempt({required this.handled, required this.data});
  final bool handled;
  final FleatherClipboardData? data;
}
