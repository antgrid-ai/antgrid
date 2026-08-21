// app/lib/widgets/file_viewer_kind.dart

/// Which specialized viewer should render a file.
enum FileViewerKind { code, markdown, svg, image, pdf }

const _markdownExts = {'md', 'markdown', 'mdx'};

String? _ext(String path) {
  final slash = path.lastIndexOf('/');
  final name = slash < 0 ? path : path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// Pure selector for the file viewer.
///
/// Markdown/SVG are text and chosen by extension. Binary kinds (image/pdf)
/// require base64 bytes ([encoding] == 'base64') and are classified by the
/// bridge-supplied [mimeType] — the single source of truth for which binaries
/// are renderable (`RENDERABLE_BINARY_MIME` in bridge/src/file-tree.ts) — so the
/// allowlist isn't duplicated app-side. Anything else falls back to the code view.
FileViewerKind fileViewerKindFor(
  String path,
  String? encoding, [
  String? mimeType,
]) {
  final ext = _ext(path);
  if (ext != null && _markdownExts.contains(ext))
    return FileViewerKind.markdown;
  if (ext == 'svg') return FileViewerKind.svg;

  if (encoding == 'base64' && mimeType != null) {
    if (mimeType.startsWith('image/')) return FileViewerKind.image;
    if (mimeType == 'application/pdf') return FileViewerKind.pdf;
  }
  return FileViewerKind.code;
}
