import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../models/file_tree_models.dart';
import 'viewer_header.dart';
import 'viewer_support.dart';

/// Renders a PDF from base64 content using pdfrx (native PDFium).
///
/// Named `FilePdfViewer` (not `PdfViewer`) to avoid colliding with pdfrx's own
/// exported `PdfViewer` widget, which this file references.
class FilePdfViewer extends StatelessWidget {
  final FileContent content;
  final VoidCallback? onClose;

  const FilePdfViewer({super.key, required this.content, this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildViewerHeader(
          fileName: viewerBasename(content.path),
          size: content.size,
          onClose: onClose,
        ),
        Expanded(
          child: Container(
            color: c.bgDeepest,
            child: DecodedBytesBuilder(
              content: content,
              builder: (context, bytes) => bytes == null
                  ? Center(
                      child: Text(
                        "Couldn't render this PDF",
                        style: AbTokens.sansStyle(color: c.textMuted),
                      ),
                    )
                  : PdfViewer.data(bytes, sourceName: content.path),
            ),
          ),
        ),
      ],
    );
  }
}
