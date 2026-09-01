import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_icon_button.dart';
import '../models/file_tree_models.dart';
import 'file_content_viewer.dart';
import 'viewer_header.dart';
import 'viewer_support.dart';

/// Scaffolds a rendered file preview with a header toggle to the source code
/// view ([FileContentViewer]). Shared by markdown and SVG viewers, which differ
/// only in the rendered body they supply via [previewBuilder].
///
/// Opens directly in source mode when a [searchLine] is set, so jumping to a
/// search match lands on the highlighted line rather than the rendered preview
/// (which can't scroll to a source line).
class PreviewWithSourceToggle extends StatefulWidget {
  final FileContent content;
  final VoidCallback? onClose;
  final VoidCallback? onRefreshContent;
  final bool fileWasModified;
  final int? searchLine;
  final String? searchQuery;
  final WidgetBuilder previewBuilder;

  /// Preview-only header actions, placed left of the source toggle. Dropped in
  /// source mode, where they have no preview to act on.
  final List<Widget> extraActions;

  const PreviewWithSourceToggle({
    super.key,
    required this.content,
    required this.previewBuilder,
    this.onClose,
    this.onRefreshContent,
    this.fileWasModified = false,
    this.searchLine,
    this.searchQuery,
    this.extraActions = const [],
  });

  @override
  State<PreviewWithSourceToggle> createState() =>
      _PreviewWithSourceToggleState();
}

class _PreviewWithSourceToggleState extends State<PreviewWithSourceToggle> {
  late bool _showSource = widget.searchLine != null;

  @override
  void didUpdateWidget(covariant PreviewWithSourceToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new search target can arrive while the file is already open (same path
    // → same State, so the field initializer above won't re-run). Jump to source
    // so the match can be scrolled to, which the rendered preview can't do.
    if (widget.searchLine != null &&
        widget.searchLine != oldWidget.searchLine) {
      _showSource = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showSource) {
      return FileContentViewer(
        fileContent: widget.content,
        selectedFilePath: widget.content.path,
        fileWasModified: widget.fileWasModified,
        onRefreshContent: widget.onRefreshContent,
        onClose: widget.onClose,
        searchLine: widget.searchLine,
        searchQuery: widget.searchQuery,
        onShowPreview: () => setState(() => _showSource = false),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildViewerHeader(
          fileName: viewerBasename(widget.content.path),
          size: widget.content.size,
          onClose: widget.onClose,
          trailing: [
            ...widget.extraActions,
            AbIconButton(
              icon: AbIcons.code,
              onTap: () => setState(() => _showSource = true),
              tooltip: 'Show source',
            ),
          ],
        ),
        if (widget.fileWasModified)
          ViewerModifiedBanner(onRefresh: widget.onRefreshContent),
        Expanded(child: widget.previewBuilder(context)),
      ],
    );
  }
}
