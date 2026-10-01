import 'dart:async' show TimeoutException;
import 'dart:io' show InternetAddress;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/widgets/ab_toast.dart';
import '../models/file_tree_models.dart' show FileResolvePathResultMessage;
import '../models/workspace_view.dart';
import '../services/file_service.dart';
import '../services/pending_reply.dart' show SessionDownException;
import '../services/preview_service.dart';
import '../widgets/attachment_preview_dialog.dart';
import '../widgets/terminal_hyperlink_sheet.dart';
import 'ab_log.dart';
import 'terminal_links.dart';

/// Longest URL echoed back to the user or written to `app.log`.
///
/// A terminal hyperlink's URI is written by whatever program is running, so it
/// is unbounded program-chosen text. `showAbToast`'s line cap stops a long
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

/// Open [url] in the system browser, falling back to a toast with the URL
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
    showAbToast(context, 'Could not open browser. Visit ${_elide(url)}.');
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
/// The destination is confirmed first unless it was already on screen, and
/// whenever the URI is shaped to be misread — see [showTerminalHyperlinkSheet]
/// for why that is not merely a nag, and [terminalHyperlinkLooksDeceptive] for
/// the shapes.
///
/// [disclosed] is the caller saying it had this exact URI painted when the
/// activation landed — `TerminalHyperlinkPreview`, in practice. It defaults to
/// false because "we showed it" is a claim only the surface that showed it can
/// make, and a caller that has no readout must not inherit one by omission.
///
/// [open] and [confirm] are injectable so tests can assert what would be
/// launched instead of handing a URL to the real browser, matching
/// `HelpAboutSection.openUrl`.
Future<void> openTerminalHyperlink(
  BuildContext context,
  String uri, {
  bool disclosed = false,
  Future<void> Function(BuildContext, String) open = openExternalUrl,
  Future<bool> Function(BuildContext, Uri) confirm = showTerminalHyperlinkSheet,
}) async {
  try {
    final target = openableTerminalHyperlink(uri);
    if (target == null) {
      // Mounted today by construction — the fork activates a tap synchronously
      // — but that is the fork's invariant, not ours, and a deferred tap (a
      // double-tap timer, a post-frame hop) would land here on a dead element.
      if (context.mounted) {
        showAbToast(
          context,
          'Only http and https links open from the terminal.',
        );
      }
      return;
    }
    if (disclosed && !terminalHyperlinkLooksDeceptive(target)) {
      await open(context, target.toString());
      return;
    }
    if (!await confirm(context, target)) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    await open(context, target.toString());
  } catch (error, stack) {
    // Log-only on purpose: every failure the user can actually provoke —
    // a refused scheme, an unparseable URL, a launcher that says no — already
    // answers with a toast above. Reaching here means something unforeseen
    // threw, and a `showAbToast` in this block could throw again with no
    // catch left to hold it.
    AbLog.error(
      'TerminalView',
      'open hyperlink failed',
      fields: {'uri': _elide(uri), 'error': '$error', 'stack': '$stack'},
    );
  }
}

/// Extracts the raw filesystem path from an OSC 8 `file://` hyperlink target,
/// or null when [uri] isn't shaped like one.
///
/// The path is handed to the bridge as-is (`FileService.resolveTerminalPath`
/// → `file:resolve-path`) and resolved there against the checkout root: only
/// the bridge machine's own platform separators are authoritative, and the
/// app never learns which OS a remote session's machine runs — so this stays
/// a syntactic unwrap, not a validity check.
String? terminalFilePath(String uri) {
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null || parsed.scheme != 'file') return null;
  if (parsed.path.isEmpty) return null;
  var path = Uri.decodeFull(parsed.path);
  // `file:///C:/Users/...` parses with a leading slash ahead of the drive
  // letter; a Windows path never actually starts with one.
  if (RegExp(r'^/[A-Za-z]:/').hasMatch(path)) {
    path = path.substring(1);
  }
  return path;
}

/// Whether [host] is a dev server's address rather than an external site's —
/// `localhost`, or any literal IPv4/IPv6 address (loopback, LAN, or a raw
/// public IP typed straight at a box). A link that names a real external
/// site by bare IP is vanishingly rare; a DOMAIN name is what a public site
/// looks like, so a hostname always falls through to the external-browser
/// path in [openContentLink] regardless of what it resolves to.
bool isLocalDevHost(String host) {
  return host.toLowerCase() == 'localhost' ||
      InternetAddress.tryParse(host) != null;
}

/// Opens a link found in ANY app surface that renders untrusted content —
/// terminal OSC 8 hyperlinks, a markdown-previewed file, or markdown inside
/// an agent chat message. Every surface routes through this one function so
/// the destinations agree everywhere the app shows a link:
///
///  * `file://...` → the Files tab, resolved via [fileService] against
///    whichever checkout the caller means (never assumed here).
///  * `http(s)://` to `localhost` or a literal IP ([isLocalDevHost]) → the
///    Preview tab via [previewService], in-app on every device — desktop
///    dials it directly, a phone tunnels it over the relay — rather than an
///    external browser that may have no route to the port at all.
///  * anything else (a search result, a docs site, a GitHub PR) → the
///    system browser, through [openTerminalHyperlink]'s existing scheme and
///    deceptive-link checks.
///
/// [terminalId] is the terminal the link was activated in, and only a terminal
/// surface passes one. It unlocks the bridge-minted `antgrid-path:` and
/// `antgrid-url:` links (see `terminal_links.dart`): a path link resolves
/// against that terminal's working directories, and a detected URL takes the
/// `http(s)` routes above with its wrapper removed. Every other caller leaves
/// it null, so those schemes fall through to [openTerminalHyperlink]'s refusal
/// — markdown and web content must not reach routes meant for the terminal.
///
/// [fileService] and [previewService] are resolved LAZILY, and re-invoked on
/// every retry rather than captured once: this awaits user dialogs, and the
/// checkout or session behind either service can be gone by the time a
/// fallback path runs.
///
/// Never completes with an error, matching [openTerminalHyperlink]'s own
/// contract — every caller discards the future this returns.
Future<void> openContentLink(
  BuildContext context,
  String uri, {
  required FileService? Function() fileService,
  required PreviewService? Function() previewService,
  required void Function(WorkspaceView) revealView,
  bool disclosed = false,
  String? terminalId,
}) async {
  if (terminalId != null && uri.startsWith(kPrintedPathLinkScheme)) {
    final link = parsePrintedPathLink(uri);
    if (link == null) {
      if (context.mounted) showAbToast(context, 'Could not open that link.');
      return;
    }
    await _openPrintedPathLink(
      context,
      link,
      terminalId,
      fileService,
      revealView,
    );
    return;
  }
  final inner = terminalId == null ? null : detectedUrlTarget(uri);
  final target = inner ?? uri;
  final parsed = Uri.tryParse(target.trim());
  // Only a link that arrived as itself may take the `file:` route: a detected
  // URL is http(s) by construction, so anything else inside the wrapper goes
  // to the scheme refusal below instead.
  if (inner == null && parsed?.scheme == 'file') {
    await _openFileLink(context, uri, fileService, revealView);
    return;
  }
  if (parsed != null &&
      (parsed.scheme == 'http' || parsed.scheme == 'https') &&
      isLocalDevHost(parsed.host)) {
    await _openPreviewLink(context, parsed, previewService, revealView);
    return;
  }
  await openTerminalHyperlink(context, target, disclosed: disclosed);
}

/// Opens a path a bridge-detected terminal link named. The bridge resolves it
/// against the one base it matched at detection, so the file opened is the one
/// the link was minted for.
Future<void> _openPrintedPathLink(
  BuildContext context,
  PrintedPathLink link,
  String terminalId,
  FileService? Function() fileService,
  void Function(WorkspaceView) revealView,
) async {
  try {
    final service = fileService();
    if (service == null) {
      if (context.mounted) {
        showAbToast(context, "Can't open that path right now.");
      }
      return;
    }
    final result = await service.resolveTerminalPath(
      link.path,
      terminalId: terminalId,
      base: link.base,
    );
    if (!context.mounted) return;
    await _showResolvedPath(context, service, result, link.line, revealView);
  } on TimeoutException {
    if (context.mounted) showAbToast(context, _unreachableMessage);
  } on SessionDownException {
    // The terminal keeps its last frame while the session is down, so detected
    // links stay clickable exactly when this fires.
    if (context.mounted) showAbToast(context, _unreachableMessage);
  } catch (error, stack) {
    AbLog.error(
      'ContentLink',
      'open path link failed',
      fields: {'error': '$error', 'stack': '$stack'},
    );
  }
}

const String _unreachableMessage =
    "Couldn't reach the machine to open that path.";

/// Opens a path a `file://` link named in the Files tab. See
/// [FileService.resolveTerminalPath] for why only the bridge can relativize
/// the path, and [FileService.revealDirectory] for the folder case.
///
/// A path outside the checkout falls back to
/// [FileResolvePathResultMessage.externalImagePath] — a recognized image type
/// (an image-generation tool's own output, typically), previewed read-only in
/// the attachment-preview dialog instead of refused outright. Anything else
/// outside the checkout is still refused: see that field's own doc for the
/// narrow, extension-only trust the bridge extends it.
Future<void> _openFileLink(
  BuildContext context,
  String rawUri,
  FileService? Function() fileService,
  void Function(WorkspaceView) revealView,
) async {
  try {
    final path = terminalFilePath(rawUri);
    if (path == null) {
      if (context.mounted) showAbToast(context, 'Could not open that link.');
      return;
    }
    final service = fileService();
    if (service == null) {
      if (context.mounted) {
        showAbToast(context, "Can't open that path right now.");
      }
      return;
    }
    final result = await service.resolveTerminalPath(path);
    if (!context.mounted) return;
    await _showResolvedPath(context, service, result, null, revealView);
  } on TimeoutException {
    if (context.mounted) showAbToast(context, _unreachableMessage);
  } on SessionDownException {
    if (context.mounted) showAbToast(context, _unreachableMessage);
  } catch (error, stack) {
    AbLog.error(
      'ContentLink',
      'open file link failed',
      fields: {'error': '$error', 'stack': '$stack'},
    );
  }
}

/// Acts on the bridge's answer to a path lookup. The order tells apart three
/// failures a user needs told apart: a path inside the workspace that has
/// since gone, one the bridge could not find or refused, and one that exists
/// but lies outside the workspace.
///
/// [FileResolvePathResultMessage.exists] is null from an older bridge, which
/// reads as present so such a bridge behaves as it always did.
Future<void> _showResolvedPath(
  BuildContext context,
  FileService service,
  FileResolvePathResultMessage result,
  int? line,
  void Function(WorkspaceView) revealView,
) async {
  final relPath = result.relPath;
  if (relPath != null) {
    if (result.exists == false) {
      showAbToast(context, 'That path no longer exists.');
      return;
    }
    revealView(WorkspaceView.files);
    if (result.isDirectory) {
      await service.revealDirectory(relPath);
    } else {
      service.selectFile(relPath, searchLine: line);
    }
    return;
  }
  final externalImagePath = result.externalImagePath;
  if (externalImagePath != null) {
    await showFilePreviewDialog(
      context,
      service,
      path: externalImagePath,
      displayName: _fileNameOf(externalImagePath),
    );
    return;
  }
  if (result.exists == false) {
    showAbToast(context, "Couldn't find that path.");
    return;
  }
  showAbToast(context, 'That path is outside this workspace.');
}

/// The last path segment of [path], tolerating either separator convention.
///
/// Not `package:path`'s `basename`: that resolves against the APP's own
/// platform, but this path names a file on the BRIDGE machine, which may run
/// a different OS — same reasoning as [terminalFilePath]'s own doc.
String _fileNameOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

/// Opens a `localhost`/IP-literal `http(s)` link in the Preview tab.
Future<void> _openPreviewLink(
  BuildContext context,
  Uri target,
  PreviewService? Function() previewService,
  void Function(WorkspaceView) revealView,
) async {
  final scheme = target.scheme;
  final port = target.hasPort ? target.port : (scheme == 'https' ? 443 : 80);
  // Reassembled rather than taken from the path alone. A hash-routed dev
  // server (Vue Router's hash mode, Angular's HashLocationStrategy) keeps the
  // WHOLE route in the fragment, so dropping it lands every such link on the
  // app's root instead of the page it named; and a URL with no path at all
  // still is not the origin once it carries a query.
  final buffer = StringBuffer(target.path.isEmpty ? '/' : target.path);
  if (target.query.isNotEmpty) buffer.write('?${target.query}');
  if (target.fragment.isNotEmpty) buffer.write('#${target.fragment}');
  final path = buffer.toString();
  try {
    final service = previewService();
    if (service == null) return;
    await service.openTab(port, scheme: scheme, path: path, navigateExisting: true);
    if (!context.mounted) return;
    revealView(WorkspaceView.preview);
  } catch (error, stack) {
    if (context.mounted) {
      showAbToast(context, 'Could not open preview on port $port.');
    }
    AbLog.error(
      'ContentLink',
      'open preview link failed',
      fields: {'error': '$error', 'stack': '$stack'},
    );
  }
}

/// Whether [target] is shaped like a link trying to pass as another one.
///
/// Judged from the URI alone, which is all a terminal hyperlink hands over.
/// Three shapes qualify, and each is a host claiming to be a host it is not:
///
///  * A userinfo prefix — `https://github.com@evil.example/` resolves to
///    `evil.example` while reading as GitHub. Dart parks the impostor in
///    [Uri.userInfo], where nothing in a URL bar's first glance looks at it.
///  * A punycoded label — `xn--pple-43d.com` renders as `apple.com`
///    with a Cyrillic first letter (U+0430).
///  * A percent-encoded host — Dart does NOT punycode a raw unicode host, it
///    percent-encodes it, so the same lie arrives spelled the other way and a
///    check for `xn--` alone misses half of it.
///
/// Deliberately not a blocklist of hosts, and deliberately silent about the
/// lookalike it cannot see: `https://github.com.evil.example/` is an honest
/// subdomain of an honest domain, and only the link's visible TEXT contradicts
/// it — text that never reaches this app. A false negative here costs the user
/// the extra confirmation, not the disclosure: the sheet names the host either
/// way, and a link that was never on screen is confirmed regardless of shape.
bool terminalHyperlinkLooksDeceptive(Uri target) {
  if (target.userInfo.isNotEmpty) {
    return true;
  }
  final host = target.host;
  if (host.contains('%')) {
    return true;
  }
  // `Uri` lower-cases the host as it parses, but the loop is what a reader
  // checks, not the parser's contract two files away.
  return host.split('.').any((label) => label.toLowerCase().startsWith('xn--'));
}
