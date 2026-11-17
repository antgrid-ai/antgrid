import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/device_stats.dart';
import '../models/file_tree_models.dart';
import 'carbon_empty_state.dart';
import 'viewer_header.dart';

/// Stands in for a binary file the app has no viewer for. The bytes are held
/// all the same, so the header's Download is the way to get the file out.
class BinaryFileViewer extends StatelessWidget {
  final FileContent content;
  final VoidCallback? onClose;

  const BinaryFileViewer({super.key, required this.content, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildViewerHeader(content: content, onClose: onClose),
        Expanded(
          child: CarbonEmptyState(
            icon: CarbonIcons.documentBlank,
            heading: 'No preview for this file type',
            body: '${formatBytes(content.size)} · Download to open it',
          ),
        ),
      ],
    );
  }
}
