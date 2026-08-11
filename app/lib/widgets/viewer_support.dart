import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../models/file_tree_models.dart';

/// Last path segment, splitting on `/` only (file:read paths are POSIX-style).
String viewerBasename(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// Human-readable byte size (B / KB / MB).
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

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
    final c = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space6,
      ),
      decoration: BoxDecoration(
        color: c.bgSurface,
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          AbIcon(AbIcons.warning, size: AbTokens.fontBody, color: c.warning),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              'File changed externally',
              style: AbTokens.sansStyle(color: c.warning),
            ),
          ),
          GestureDetector(
            onTap: onRefresh,
            child: Text(
              'Refresh',
              style: AbTokens.sansStyle(color: c.accent),
            ),
          ),
        ],
      ),
    );
  }
}
