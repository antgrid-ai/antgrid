import 'package:flutter/widgets.dart';

import '../models/file_tree_models.dart';
import 'file_content_viewer.dart';
import 'file_viewer_kind.dart';
import 'image_viewer.dart';
import 'markdown_preview.dart';
import 'pdf_viewer.dart';
import 'svg_preview.dart';

/// Inspects the open file and delegates to the right viewer. Loading, empty,
/// and error states (plus all code/text files) go to [FileContentViewer].
class FileViewerRouter extends StatelessWidget {
  final FileContent? fileContent;
  final bool isLoading;
  final String? selectedFilePath;
  final bool fileWasModified;
  final VoidCallback? onRefreshContent;
  final VoidCallback? onClose;
  final int? searchLine;
  final String? searchQuery;

  const FileViewerRouter({
    super.key,
    this.fileContent,
    this.isLoading = false,
    this.selectedFilePath,
    this.fileWasModified = false,
    this.onRefreshContent,
    this.onClose,
    this.searchLine,
    this.searchQuery,
  });

  Widget _source() => FileContentViewer(
    fileContent: fileContent,
    isLoading: isLoading,
    selectedFilePath: selectedFilePath,
    fileWasModified: fileWasModified,
    onRefreshContent: onRefreshContent,
    onClose: onClose,
    searchLine: searchLine,
    searchQuery: searchQuery,
  );

  @override
  Widget build(BuildContext context) {
    final fc = fileContent;
    if (isLoading || fc == null || fc.error != null) return _source();

    switch (fileViewerKindFor(fc.path, fc.encoding, fc.mimeType)) {
      case FileViewerKind.markdown:
        return MarkdownPreview(
          key: ValueKey(fc.path),
          content: fc,
          onClose: onClose,
          onRefreshContent: onRefreshContent,
          fileWasModified: fileWasModified,
          searchLine: searchLine,
          searchQuery: searchQuery,
        );
      case FileViewerKind.svg:
        return SvgPreview(
          key: ValueKey(fc.path),
          content: fc,
          onClose: onClose,
          onRefreshContent: onRefreshContent,
          fileWasModified: fileWasModified,
          searchLine: searchLine,
          searchQuery: searchQuery,
        );
      case FileViewerKind.image:
        return ImageViewer(
          key: ValueKey(fc.path),
          content: fc,
          onClose: onClose,
        );
      case FileViewerKind.pdf:
        return FilePdfViewer(
          key: ValueKey(fc.path),
          content: fc,
          onClose: onClose,
        );
      case FileViewerKind.code:
        return _source();
    }
  }
}
