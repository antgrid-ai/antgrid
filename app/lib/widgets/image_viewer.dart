import 'package:flutter/widgets.dart';

import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../models/file_tree_models.dart';
import 'viewer_header.dart';
import 'viewer_support.dart';

/// Renders a raster image decoded from base64 content.
class ImageViewer extends StatelessWidget {
  final FileContent content;
  final VoidCallback? onClose;

  const ImageViewer({super.key, required this.content, this.onClose});

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
            padding: const EdgeInsets.all(AbTokens.space4),
            child: DecodedBytesBuilder(
              content: content,
              builder: (context, bytes) => bytes == null
                  ? _failure(c)
                  : InteractiveViewer(
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        errorBuilder: (context, _, stackTrace) => _failure(c),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _failure(AbColors c) => Center(
        child: Text(
          "Couldn't render this image",
          style: AbTokens.sansStyle(color: c.textMuted),
        ),
      );
}
