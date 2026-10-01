/// The links the bridge mints for plain-text paths and URLs a terminal printed.
///
/// Mirrored BY HAND from `bridge/src/terminal-links/grammar.ts`
/// (`encodePathLink`, `encodeUrlLink` and the constants beside them): the two
/// sides share no code and no suite spans them, so a change to the parameter
/// order, the caps or the base/kind letters there has to land here in the same
/// commit.
///
/// Only the bridge's detector produces these URIs; a terminal program that
/// writes one itself has it dropped before it reaches a frame. They are still
/// untrusted input here, so every parser below answers null for anything
/// malformed instead of guessing.
library;

const kPrintedPathLinkScheme = 'antgrid-path:';
const kDetectedUrlLinkScheme = 'antgrid-url:';

/// Parse cap on the printed path, in UTF-16 units (`MAX_PRINTED_PATH_CHARS`).
const kMaxPrintedPathChars = 1024;
const kMaxPrintedLine = 10000000;
const kMaxPrintedColumn = 100000;

const _bases = {'a', 'l', 's', 'r'};
final _decimal = RegExp(r'^\d+$');

/// Whether [uri] is one the bridge's detector minted.
///
/// Top-level on purpose: `GhosttyTerminalView` receives it as
/// `isQuietHyperlink`, and a stable identity is what lets the view skip
/// recomputing link classes. Case-sensitive because the bridge emits lowercase
/// only.
bool isDetectedTerminalLink(String uri) =>
    uri.startsWith(kPrintedPathLinkScheme) ||
    uri.startsWith(kDetectedUrlLinkScheme);

enum PrintedPathKind { file, directory, image }

final class PrintedPathLink {
  const PrintedPathLink({
    required this.path,
    required this.base,
    this.kind,
    this.line,
    this.column,
  });

  /// The path exactly as the terminal printed it: never resolved, absolute
  /// only when it was printed absolute.
  final String path;

  /// The base the detector matched: `a` printed absolute, `l` live cwd,
  /// `s` spawn cwd, `r` checkout root.
  final String base;

  /// What the bridge found when it detected the link; null for a kind this
  /// app does not know.
  final PrintedPathKind? kind;
  final int? line;
  final int? column;
}

int? _boundedDecimal(String? raw, int max) {
  if (raw == null || !_decimal.hasMatch(raw)) return null;
  final value = int.tryParse(raw);
  if (value == null || value < 1 || value > max) return null;
  return value;
}

/// Parses an `antgrid-path:` link, or null when it is not one or is malformed.
PrintedPathLink? parsePrintedPathLink(String uri) {
  if (!uri.startsWith(kPrintedPathLinkScheme)) return null;
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return null;
  final Map<String, String> params;
  try {
    // An escape that decodes to invalid UTF-8 throws, and a decoded `%` is
    // legitimate (a printed path may contain one, which the bridge encodes as
    // `%25`), so the only guard here is the catch.
    params = parsed.queryParameters;
  } on FormatException {
    return null;
  }
  final path = params['p'];
  if (path == null || path.isEmpty || path.length > kMaxPrintedPathChars) {
    return null;
  }
  final base = params['b'];
  if (base == null || !_bases.contains(base)) return null;
  final PrintedPathKind? kind = switch (params['k']) {
    'f' => PrintedPathKind.file,
    'd' => PrintedPathKind.directory,
    'i' => PrintedPathKind.image,
    _ => null,
  };
  final line = _boundedDecimal(params['n'], kMaxPrintedLine);
  // A column is meaningless without its line, and the bridge never emits one.
  final column = line == null
      ? null
      : _boundedDecimal(params['c'], kMaxPrintedColumn);
  return PrintedPathLink(
    path: path,
    base: base,
    kind: kind,
    line: line,
    column: column,
  );
}

/// The URL inside an `antgrid-url:` link, or null when [uri] is not one.
///
/// A raw prefix strip, never `Uri.parse` on the wrapper: the inner `?` and `#`
/// would split it.
String? detectedUrlTarget(String uri) {
  if (!uri.startsWith(kDetectedUrlLinkScheme)) return null;
  final inner = uri.substring(kDetectedUrlLinkScheme.length);
  return inner.isEmpty ? null : inner;
}

/// `src/a.ts`, `src/a.ts:12` or `src/a.ts:12:5`.
String printedPathLabel(PrintedPathLink link) {
  final line = link.line;
  if (line == null) return link.path;
  final column = link.column;
  return column == null
      ? '${link.path}:$line'
      : '${link.path}:$line:$column';
}
