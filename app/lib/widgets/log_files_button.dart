import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_toast.dart';
import '../util/detached.dart';
import '../util/log_location.dart';
import '../util/log_sharing.dart';

/// 'share logs' on Android/iOS (no file manager, so the share sheet is the
/// only way the log leaves the device); 'open log folder' on desktop.
String logFilesActionLabel({TargetPlatform? platform}) =>
    logsLiveInAppSupport(platform ?? defaultTargetPlatform)
    ? 'share logs'
    : 'open log folder';

class LogFilesButton extends StatelessWidget {
  const LogFilesButton({
    super.key,
    this.compact = false,
    this.uppercase = false,
    @visibleForTesting this.share,
    @visibleForTesting this.openFolder,
  });

  final bool compact;
  final bool uppercase;
  final Future<LogShareOutcome> Function(Rect? origin)? share;
  final Future<bool> Function()? openFolder;

  @override
  Widget build(BuildContext context) {
    final label = logFilesActionLabel();
    return AbButton(
      label: uppercase ? label.toUpperCase() : label,
      compact: compact,
      onTap: () => detached(
        'LogFilesButton',
        'log files action',
        () => _run(context),
      ),
    );
  }

  Future<void> _run(BuildContext context) async {
    // Everything that needs the context is read before the first await.
    final toaster = AbToaster.maybeOf(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    if (logsLiveInAppSupport(defaultTargetPlatform)) {
      final outcome = await (share ?? (o) => shareAppLogs(origin: o))(origin);
      switch (outcome) {
        case LogShareOutcome.noLogFiles:
          toaster?.showMessage('No log file on this device yet.');
        case LogShareOutcome.failed:
          toaster?.showMessage('Could not open the share sheet for the logs.');
        case LogShareOutcome.presented:
          break;
      }
    } else {
      final ok = await (openFolder ?? openLogFolder)();
      if (!ok) toaster?.showMessage('Could not open the log folder.');
    }
  }
}
