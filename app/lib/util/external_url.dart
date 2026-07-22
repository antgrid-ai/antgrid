import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/widgets/ab_snack_bar.dart';

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
