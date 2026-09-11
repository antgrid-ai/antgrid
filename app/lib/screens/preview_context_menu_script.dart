import 'dart:convert';

/// Vanilla-JS content script that reports right-click context back to Dart,
/// so the preview panel can show an Antgrid-styled menu in place of the
/// native one — WebView2's own default context menu is disabled at the
/// native-plugin level (`webview_all_windows`'s
/// `AreDefaultContextMenusEnabled(FALSE)`, with no Dart-side toggle), which
/// is the standard way an embedder hands the menu to its own UI rather than
/// leaving right-click doing nothing.
///
/// Persistent, unlike [kElementPickerScript]: re-injected on every
/// `onPageFinished` (a real navigation tears down the JS world, taking the
/// listener with it) but never armed/disarmed on demand — right-click should
/// always work, not just while some tool is active. The guard flag still
/// matters: `onPageFinished` can fire more than once for the same document
/// (e.g. a same-page hash change), and a second listener would double-post.
///
/// Posts one message via the `AntgridContextMenu` JS channel:
/// `{type: "contextmenu", href, imgSrc, selectionText, editable, pageUrl}`.
/// `href`/`imgSrc` are read off the element's DOM property (never the raw
/// attribute), which the browser already resolves to an absolute URL —
/// exactly the shape [parsePreviewTarget]-style local-port parsing and
/// [openContentLink]'s local/external split both expect.
const String kContextMenuScript = '''
(function() {
  if (window.__antgridContextMenuArmed) return;
  window.__antgridContextMenuArmed = true;

  function onContextMenu(e) {
    // The native menu is already off (see the doc above); this is
    // belt-and-suspenders for any backend where it isn't, and stops the
    // page's OWN custom context menu (if it installs one) from double-firing
    // alongside ours.
    e.preventDefault();

    var link = e.target.closest ? e.target.closest('a[href]') : null;
    var img = e.target.closest ? e.target.closest('img[src]') : null;

    var editable = false;
    var cur = e.target;
    while (cur) {
      if (cur.tagName === 'INPUT' || cur.tagName === 'TEXTAREA' || cur.isContentEditable) {
        editable = true;
        break;
      }
      cur = cur.parentElement;
    }

    var selectionText = '';
    try {
      selectionText = (window.getSelection && window.getSelection().toString()) || '';
    } catch (err) {}

    var payload = {
      type: 'contextmenu',
      href: link ? link.href : null,
      imgSrc: img ? img.src : null,
      selectionText: selectionText,
      editable: editable,
      pageUrl: location.href
    };
    if (window.AntgridContextMenu) {
      window.AntgridContextMenu.postMessage(JSON.stringify(payload));
    }
  }

  document.addEventListener('contextmenu', onContextMenu, false);
})();
''';

/// Inserts [text] at the focused element's caret via the same mechanism a
/// real browser's own Paste uses — `execCommand('insertText', …)` fires a
/// proper `input` event, which is what a framework-controlled field (React,
/// Vue) listens for, unlike setting `.value` directly. Scoped to whatever
/// element the page itself currently has focused; there is no Flutter-side
/// caret to target since the webview is an opaque platform surface.
String buildContextMenuPasteScript(String text) {
  return "document.execCommand('insertText', false, ${jsonEncode(text)});";
}

/// Deletes the current selection — the second half of Cut, after the text is
/// already copied to the OS clipboard Dart-side. Only ever sent when the
/// menu's own `editable` flag was true, so this never runs against read-only
/// selected text.
const String kContextMenuDeleteSelectionScript = "document.execCommand('delete');";

/// Selects the whole page's content — the context menu's "Select all", same
/// mechanism a real browser uses. Works whether or not the click landed in an
/// editable field: `execCommand('selectAll')` selects that field's own text
/// when focus is inside one, and the document body otherwise.
const String kContextMenuSelectAllScript = "document.execCommand('selectAll');";

/// One right-click's worth of DOM context, decoded from the
/// `AntgridContextMenu` channel's `contextmenu` message. `href`/`imgSrc` are
/// normalized to `null` rather than an empty string so callers can test
/// presence with a plain null check.
class PreviewContextMenuInfo {
  const PreviewContextMenuInfo({
    this.href,
    this.imgSrc,
    this.selectionText = '',
    this.editable = false,
    this.pageUrl,
  });

  /// No context reached Dart in time — see the fallback timer in
  /// `PreviewScreen`. Still worth a menu (Reload / Copy page URL), just with
  /// nothing element-specific to offer.
  const PreviewContextMenuInfo.empty() : this();

  final String? href;
  final String? imgSrc;
  final String selectionText;
  final bool editable;
  final String? pageUrl;
}

/// Parses one `AntgridContextMenu` channel message, or null if it isn't a
/// well-formed `contextmenu` payload. [rawMessage] is untrusted — parsed
/// from a message posted by arbitrary web content running in the preview —
/// so every field is handled as possibly missing or the wrong type; this
/// never throws.
PreviewContextMenuInfo? parseContextMenuMessage(String rawMessage) {
  Object? decoded;
  try {
    decoded = jsonDecode(rawMessage);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['type'] != 'contextmenu') return null;

  String? nonEmptyString(Object? value) {
    return value is String && value.isNotEmpty ? value : null;
  }

  return PreviewContextMenuInfo(
    href: nonEmptyString(decoded['href']),
    imgSrc: nonEmptyString(decoded['imgSrc']),
    selectionText: decoded['selectionText'] is String
        ? decoded['selectionText'] as String
        : '',
    editable: decoded['editable'] == true,
    pageUrl: nonEmptyString(decoded['pageUrl']),
  );
}
