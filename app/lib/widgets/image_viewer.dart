import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/file_tree_models.dart';
import 'viewer_header.dart';
import 'viewer_support.dart';
import 'zoomable_image.dart';

/// Renders a raster image decoded from base64 content. Pinch or double-tap to
/// zoom; see [ZoomableImage] for how that coexists with the phone's page swipe.
class ImageViewer extends StatelessWidget {
  final FileContent content;
  final VoidCallback? onClose;

  const ImageViewer({super.key, required this.content, this.onClose});

  static const _failure = ViewerErrorNotice(
    message: "Couldn't render this image",
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildViewerHeader(content: content, onClose: onClose),
        Expanded(
          child: ColoredBox(
            color: CarbonTheme.of(context).colors.background,
            child: Padding(
              padding: const EdgeInsets.all(CarbonSpacing.spacing02),
              child: DecodedBytesBuilder(
                content: content,
                builder: (context, bytes) => bytes == null
                    ? _failure
                    : ZoomableImage(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          errorBuilder: (context, _, stackTrace) => _failure,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
