import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/ab_toast.dart';

/// Copies [path] to the clipboard and says so in a toast.
///
/// A clipboard the platform refuses to write (a Linux session with no
/// clipboard owner) throws; caught here it becomes a toast, where it would
/// otherwise escape every caller into a debugPrint and leave the user with a
/// stale clipboard they believe they just replaced.
Future<void> copyPathWithToast(BuildContext context, String path) async {
  try {
    await Clipboard.setData(ClipboardData(text: path));
  } catch (_) {
    if (context.mounted) showAbToast(context, 'Could not copy the path.');
    return;
  }
  if (context.mounted) showAbToast(context, 'Path copied');
}
