import 'package:fleather/fleather.dart';

import '../../../services/clipboard_image_reader.dart';

/// Resolves one paste into either an attachment or document text.
///
/// A null return tells Fleather to insert nothing — which is what routes an
/// image to the attachment strip instead of into the prompt body.
///
/// An image wins over text the same clipboard also carries: a source that
/// offers both (a browser, a spreadsheet) is offering one picture, and its
/// text is that picture's markup rather than what the user meant to paste.
Future<FleatherClipboardData?> resolveComposerPaste({
  required ClipboardImageReader readImage,
  required void Function(PastedImage) onImagePasted,
  required Future<FleatherClipboardData?> Function() readText,
  void Function(Object error, StackTrace stack)? onImageReadError,
}) async {
  try {
    final image = await readImage();
    if (image != null) {
      onImagePasted(image);
      return null;
    }
  } catch (error, stack) {
    // A clipboard probe must never break paste — fall through to text.
    onImageReadError?.call(error, stack);
  }
  return readText();
}
