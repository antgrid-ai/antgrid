import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/widgets/ab_snack_bar.dart';
import 'ab_log.dart';

/// Longest URL echoed back to the user or written to `app.log`.
///
/// A terminal hyperlink's URI is written by whatever program is running, so it
/// is unbounded program-chosen text. `showAbSnackBar`'s line cap stops a long
/// one being PAINTED but not laid out, and the log line would carry all of it
/// to disk on every failure.
const int _maxShownUrlChars = 120;

String _elide(String url) {
  if (url.length <= _maxShownUrlChars) return url;
  // Back off a trailing high surrogate: `substring` cuts UTF-16 code units, and
  // a stranded half renders as a replacement glyph and corrupts the logged URI
  // at exactly the character a reader is trying to identify.
  final last = url.codeUnitAt(_maxShownUrlChars - 1);
  final end = (last >= 0xD800 && last <= 0xDBFF)
      ? _maxShownUrlChars - 1
      : _maxShownUrlChars;
  return '${url.substring(0, end)}…';
}

/// Open [url] in the system browser, falling back to a SnackBar with the URL
/// if launching fails. Used by the sign-in / activation / blocked screens and
/// by [openTerminalHyperlink].
Future<void> openExternalUrl(BuildContext context, String url) async {
  // tryParse, not parse: [openTerminalHyperlink] hands this URLs it did not
  // author, and a FormatException here would escape a caller whose future is
  // discarded. An unparseable URL takes the same visible path as a failed
  // launch rather than vanishing into a log line.
  final parsed = Uri.tryParse(url);
  bool ok = false;
  if (parsed != null) {
    try {
      ok = await launchUrl(parsed, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && context.mounted) {
    showAbSnackBar(context, 'Could not open browser. Visit ${_elide(url)}.');
  }
}

/// The URI to open for a hyperlink carried by terminal output, or null when it
/// may not be opened.
///
/// An OSC 8 payload is written by whatever program is running in the terminal,
/// so a tap on it acts on untrusted input rather than on something the user
/// typed. Only the web schemes pass: `file:` would hand out local paths and a
/// custom scheme could deep-link into another installed app.
///
/// This bounds the SCHEME and nothing else. The host is not vetted, OSC 8 lets
/// a link's visible text disagree with its target, and `openExternalUrl` hands
/// the URI to the OS with [LaunchMode.externalApplication] — so an `https:`
/// host holding a verified App Link still opens that app rather than a browser.
///
/// Returns the parsed URI rather than a bool so the caller opens exactly what
/// was checked. Validating one string and launching another is how a padded
/// URI cleared the scheme check and then reached `Uri.parse` with the padding
/// still on it, where it throws.
Uri? openableTerminalHyperlink(String uri) {
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null) return null;
  // `Uri` lower-cases the scheme as it parses, so a literal compare is total.
  if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
  return parsed.host.isEmpty ? null : parsed;
}

/// Open a hyperlink activated in the terminal, refusing non-web schemes.
///
/// Never completes with an error. The terminal view discards the future this
/// returns, so a rejection would reach `PlatformDispatcher.onError` as a fatal
/// carrying no in-app frames.
///
/// [open] is injectable so tests can assert what would be launched instead of
/// handing a URL to the real browser, matching `HelpAboutSection.openUrl`.
Future<void> openTerminalHyperlink(
  BuildContext context,
  String uri, {
  Future<void> Function(BuildContext, String) open = openExternalUrl,
}) async {
  try {
    final target = openableTerminalHyperlink(uri);
    if (target == null) {
      // Mounted today by construction — the fork activates a tap synchronously
      // — but that is the fork's invariant, not ours, and a deferred tap (a
      // double-tap timer, a post-frame hop) would land here on a dead element.
      if (context.mounted) {
        showAbSnackBar(
          context,
          'Only http and https links open from the terminal.',
        );
      }
      return;
    }
    await open(context, target.toString());
  } catch (error, stack) {
    // Log-only on purpose: every failure the user can actually provoke —
    // a refused scheme, an unparseable URL, a launcher that says no — already
    // answers with a SnackBar above. Reaching here means something unforeseen
    // threw, and a `showAbSnackBar` in this block could throw again with no
    // catch left to hold it.
    AbLog.error(
      'TerminalView',
      'open hyperlink failed',
      fields: {'uri': _elide(uri), 'error': '$error', 'stack': '$stack'},
    );
  }
}
