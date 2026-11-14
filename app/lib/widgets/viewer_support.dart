import 'dart:convert';
import 'dart:typed_data';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/file_tree_models.dart';
import 'carbon_empty_state.dart';

/// Last path segment. Checkout paths are POSIX-style, where a backslash is a
/// legal filename character; only an image outside the checkout arrives as the
/// host's own absolute path, which on Windows is backslashed — so a backslash
/// separates only in a drive- or UNC-rooted path.
String viewerBasename(String path) {
  final separator = _windowsAbsolute.hasMatch(path) ? r'[\\/]' : '/';
  final segments = path.split(RegExp(separator)).where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

final _windowsAbsolute = RegExp(r'^([A-Za-z]:[\\/]|\\\\)');

/// Decodes base64 file content to bytes, returning null on absent or malformed
/// input so callers can show a render-failure placeholder.
Uint8List? decodeBase64Content(String? raw) {
  if (raw == null) return null;
  try {
    return base64Decode(raw);
  } catch (_) {
    return null;
  }
}

/// Decodes [content] to bytes once and rebuilds [builder] with the result.
///
/// Decoding once (in initState, refreshed only when the payload changes) keeps a
/// multi-MB base64 string from being re-decoded on every rebuild — and gives
/// pdfrx a stable byte reference so it doesn't re-open the document and lose
/// scroll position. [builder] receives null when the content is absent or not
/// valid base64, so callers can show a render-failure placeholder.
class DecodedBytesBuilder extends StatefulWidget {
  final FileContent content;
  final Widget Function(BuildContext context, Uint8List? bytes) builder;

  const DecodedBytesBuilder({
    super.key,
    required this.content,
    required this.builder,
  });

  @override
  State<DecodedBytesBuilder> createState() => _DecodedBytesBuilderState();
}

class _DecodedBytesBuilderState extends State<DecodedBytesBuilder> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = decodeBase64Content(widget.content.content);
  }

  @override
  void didUpdateWidget(covariant DecodedBytesBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content.content != oldWidget.content.content) {
      _bytes = decodeBase64Content(widget.content.content);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _bytes);
}

/// Banner shown above any viewer when the open file changed on disk.
class ViewerModifiedBanner extends StatelessWidget {
  final VoidCallback? onRefresh;

  const ViewerModifiedBanner({super.key, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return CarbonNotification(
      kind: CarbonNotificationKind.warning,
      title: 'File changed externally',
      action: CarbonNotificationAction(label: 'Refresh', onPressed: onRefresh),
    );
  }
}

/// An icon-only viewer tool whose [label] is both its accessible name and its
/// tooltip. [selected] latches a toggle such as Find.
class ViewerIconButton extends StatelessWidget {
  const ViewerIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.selected,
  });

  final CarbonIcons icon;
  final String label;
  final VoidCallback? onPressed;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    return CarbonButton.iconOnly(
      icon: CarbonIcon(icon),
      semanticLabel: label,
      selected: selected,
      onPressed: onPressed,
    );
  }
}

/// A viewer's pane while its file is still being read.
class ViewerLoadingState extends StatelessWidget {
  const ViewerLoadingState({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CarbonLoading(size: CarbonLoadingSize.small));
}

/// The pane for a file that no longer exists, with a way back out.
class ViewerDeletedState extends StatelessWidget {
  const ViewerDeletedState({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return CarbonEmptyState(
      icon: CarbonIcons.close,
      heading: 'This file was deleted',
      action: CarbonButton(
        label: 'Close',
        kind: CarbonButtonKind.ghost,
        onPressed: onClose,
      ),
    );
  }
}

/// A read or render failure shown inline in the viewer's pane.
class ViewerErrorNotice extends StatelessWidget {
  const ViewerErrorNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(CarbonSpacing.spacing05),
      child: CarbonNotification(
        kind: CarbonNotificationKind.error,
        subtitle: message,
      ),
    );
  }
}
