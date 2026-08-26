import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/widgets/ab_snack_bar.dart';
import 'ab_log.dart';

/// Open [url] in the system browser, falling back to a SnackBar with the URL
/// if launching fails. Used by the sign-in / activation / blocked screens.
Future<void> openExternalUrl(BuildContext context, String url) async {
  final parsed = Uri.parse(url);
  bool ok = false;
  try {
    ok = await launchUrl(parsed, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    showAbSnackBar(context, 'Could not open browser. Visit $url.');
  }
}

/// Whether a hyperlink carried by terminal output may be opened.
///
/// An OSC 8 payload is written by whatever program is running in the terminal,
/// so a tap on it acts on untrusted input rather than on something the user
/// typed. Only the web schemes pass: `file:` would hand out local paths and a
/// custom scheme could deep-link into another installed app.
bool isOpenableTerminalHyperlink(String uri) {
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null) return false;
  final scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  return parsed.host.isNotEmpty;
}

/// Open a hyperlink activated in the terminal, refusing non-web schemes.
///
/// Never completes with an error. The terminal view discards the future this
/// returns, so a rejection would reach `PlatformDispatcher.onError` as a fatal
/// carrying no in-app frames — the same hazard [detached] exists for, which
/// this cannot use because the view wants a future back.
Future<void> openTerminalHyperlink(BuildContext context, String uri) async {
  try {
    if (!isOpenableTerminalHyperlink(uri)) {
      showAbSnackBar(
        context,
        'Only http and https links open from the terminal.',
      );
      return;
    }
    await openExternalUrl(context, uri);
  } catch (error, stack) {
    AbLog.error(
      'terminal',
      'open hyperlink failed',
      fields: {'uri': uri, 'error': '$error', 'stack': '$stack'},
    );
  }
}
