/// Where a tap on a link inside a rendered markdown document should go.
enum MarkdownLinkKind {
  /// A web address, handed to the system browser.
  external,

  /// Another file in the project, opened in the file viewer.
  repoFile,

  /// A heading in the document being read.
  anchor,

  /// Nothing safe or meaningful to do.
  unsupported,
}

/// The resolved destination of a markdown link.
class MarkdownLinkTarget {
  const MarkdownLinkTarget(this.kind, this.value);

  final MarkdownLinkKind kind;

  /// The URL, project-relative path, or heading fragment named by [kind];
  /// empty for [MarkdownLinkKind.unsupported].
  final String value;

  static const unsupported = MarkdownLinkTarget(
    MarkdownLinkKind.unsupported,
    '',
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownLinkTarget &&
      other.kind == kind &&
      other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'MarkdownLinkTarget(${kind.name}, $value)';
}

/// Classify [href] as written in the document at [fromPath].
///
/// Repo docs mix three link shapes that need three different answers, and
/// markdown_widget's own default — `launchUrl(Uri.parse(href))` on every one of
/// them — is right for only the first: a relative path reaches the OS as a
/// schemeless URI and a `#anchor` as an empty one.
///
/// Only `http`/`https`/`mailto` open externally: a document is repository
/// content, so `file:` would hand out local paths and a custom scheme could
/// deep-link into another installed app. That is `openableTerminalHyperlink`'s
/// set plus `mailto`, which a doc's contact line legitimately uses.
MarkdownLinkTarget resolveMarkdownLink(
  String href, {
  required String fromPath,
}) {
  final trimmed = href.trim();
  if (trimmed.isEmpty) return MarkdownLinkTarget.unsupported;

  if (trimmed.startsWith('#')) {
    final fragment = trimmed.substring(1);
    return fragment.isEmpty
        ? MarkdownLinkTarget.unsupported
        : MarkdownLinkTarget(MarkdownLinkKind.anchor, fragment);
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    // A single-letter scheme is a Windows drive, not a protocol — `Uri` reads
    // `C:/notes.md` as scheme `c`. It is neither a URL to open nor a path
    // inside the checkout, so it resolves to nothing.
    if (parsed.scheme.length == 1) return MarkdownLinkTarget.unsupported;
    if (parsed.scheme == 'http' || parsed.scheme == 'https') {
      // A hostless `http:///x` reaches the OS as a URL that opens nothing;
      // `openableTerminalHyperlink` refuses it for the same reason.
      return parsed.host.isEmpty
          ? MarkdownLinkTarget.unsupported
          : MarkdownLinkTarget(MarkdownLinkKind.external, trimmed);
    }
    return parsed.scheme == 'mailto'
        ? MarkdownLinkTarget(MarkdownLinkKind.external, trimmed)
        : MarkdownLinkTarget.unsupported;
  }

  // A protocol-relative URL (`//host/path`) carries an authority and no scheme,
  // so it is a web address wearing a path's clothes — resolving it against the
  // checkout would name a file after someone else's hostname.
  if (trimmed.startsWith('//')) return MarkdownLinkTarget.unsupported;

  final path = _stripSuffixes(trimmed);
  // A trailing slash names a directory, and the viewer opens files.
  if (path.isEmpty || path.endsWith('/')) return MarkdownLinkTarget.unsupported;

  final resolved = _resolveProjectPath(fromPath, _decode(path));
  return resolved == null
      ? MarkdownLinkTarget.unsupported
      : MarkdownLinkTarget(MarkdownLinkKind.repoFile, resolved);
}

/// The GitHub-style anchor slug for [text].
///
/// ASCII-folding only: the full algorithm keeps unicode letters, but every
/// heading that a repo doc actually cross-references is ASCII, and a wrong
/// match is worse than no match — [resolveMarkdownLink]'s caller simply stays
/// put when nothing matches.
String slugifyMarkdownHeading(String text) => text
    .toLowerCase()
    .trim()
    .replaceAll(_slugPunctuation, '')
    .replaceAll(_slugWhitespace, '-');

/// Step for step `package:markdown`'s `BlockSyntax.generateAnchorHash`, which
/// is what actually stamped the `id` onto the heading this slug has to match.
/// One hyphen per whitespace CHARACTER, so `Dev & setup` is `dev--setup` —
/// collapsing the run would miss every heading holding stripped punctuation.
final RegExp _slugPunctuation = RegExp(r'[^a-z0-9 _-]');
final RegExp _slugWhitespace = RegExp(r'\s');

String _stripSuffixes(String href) {
  final cut = href.indexOf(RegExp(r'[#?]'));
  return cut < 0 ? href : href.substring(0, cut);
}

String _decode(String path) {
  try {
    return Uri.decodeComponent(path);
  } on ArgumentError {
    // A stray `%` is a literal in someone's filename, not an escape.
    return path;
  } on FormatException {
    // A well-formed escape can still decode to bytes that are not UTF-8 —
    // `%E9` is latin-1 `é`, which exporters still emit. Both throws have to be
    // caught here: this runs inside a tap handler, where an escape is fatal.
    return path;
  }
}

/// Join [href] onto the directory holding [fromPath], collapsing `.` and `..`.
///
/// Returns null when the walk climbs past the project root: the bridge only
/// serves paths inside the checkout, so an escaping link has no destination to
/// offer rather than a forbidden one.
String? _resolveProjectPath(String fromPath, String href) {
  final segments = <String>[];
  if (!href.startsWith('/')) {
    final slash = fromPath.lastIndexOf('/');
    if (slash > 0) segments.addAll(fromPath.substring(0, slash).split('/'));
  }
  for (final segment in href.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) return null;
      segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.isEmpty ? null : segments.join('/');
}
