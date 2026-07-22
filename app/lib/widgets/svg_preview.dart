import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../models/file_tree_models.dart';
import 'preview_with_source_toggle.dart';

/// Renders an SVG file. Defaults to the rendered vector; a header toggle
/// switches to the source code view.
class SvgPreview extends StatelessWidget {
  final FileContent content;
  final VoidCallback? onClose;
  final VoidCallback? onRefreshContent;
  final bool fileWasModified;
  final int? searchLine;
  final String? searchQuery;

  const SvgPreview({
    super.key,
    required this.content,
    this.onClose,
    this.onRefreshContent,
    this.fileWasModified = false,
    this.searchLine,
    this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    return PreviewWithSourceToggle(
      content: content,
      onClose: onClose,
      onRefreshContent: onRefreshContent,
      fileWasModified: fileWasModified,
      searchLine: searchLine,
      searchQuery: searchQuery,
      previewBuilder: (context) {
        final svg = content.content ?? '';
        return Container(
          color: context.antgrid.bgDeepest,
          padding: const EdgeInsets.all(AbTokens.space4),
          child: svg.isEmpty
              ? const SizedBox.shrink()
              : SvgPicture.string(svg,
                  key: const Key('svg-content'), fit: BoxFit.contain),
        );
      },
    );
  }
}
