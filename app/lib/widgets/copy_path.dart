import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/ab_toast.dart';

/// Copies [text] to the clipboard and says so in a toast: [copied] on success,
/// [failed] when the clipboard refuses the write.
///
/// A clipboard the platform refuses to write (a Linux session with no
/// clipboard owner) throws; caught here it becomes a toast, where it would
/// otherwise escape every caller into a debugPrint and leave the user with a
/// stale clipboard they believe they just replaced.
Future<void> copyTextWithToast(
  BuildContext context,
  String text, {
  required String copied,
  required String failed,
}) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    if (context.mounted) showAbToast(context, failed);
    return;
  }
  if (context.mounted) showAbToast(context, copied);
}

Future<void> copyPathWithToast(BuildContext context, String path) =>
    copyTextWithToast(
      context,
      path,
      copied: 'Path copied',
      failed: 'Could not copy the path.',
    );
