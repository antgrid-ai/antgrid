import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon_button.dart';
import '../../../design/widgets/ab_tap_target.dart';

enum AttachmentStatus { uploading, done, error }

/// One file attached to the composer. Mutable: the owning widget updates
/// status/progress in setState as the upload advances.
class ComposerAttachment {
  ComposerAttachment({
    required this.fileName,
    required this.bytes,
    this.mimeType,
  });

  final String fileName;

  /// Sent with the upload so the bridge can record the type it was told; a
  /// picked file leaves it null (the name carries the extension).
  final String? mimeType;

  /// Kept until the upload succeeds so an error chip can retry without
  /// re-picking; nulled on success to release up to 20 MB promptly.
  Uint8List? bytes;

  AttachmentStatus status = AttachmentStatus.uploading;
  double progress = 0;

  /// Absolute path on the bridge machine — what the prompt text references.
  String? path;

  /// Project-relative twin of [path], the only form `file:read` accepts, so it
  /// is what a preview reads by. Null from a bridge predating the field, which
  /// simply means no preview rather than a guessed path.
  String? relPath;

  /// The bridge's own verdict on whether it can render this file, from the same
  /// table `file:read` answers from. Null = no viewer for it. Distinct from
  /// [mimeType], which is only what the app DECLARED at attach time and is not
  /// evidence of anything.
  String? previewMimeType;

  /// Downscaled still, decoded while [bytes] was still held. A pasted image is
  /// named `pasted-image.png`, which identifies nothing — the thumbnail is how
  /// the user tells two of them apart.
  Uint8List? thumbnail;

  /// A preview needs a readable path AND a type the bridge admits to rendering.
  /// Both come from the upload result, so this is only ever true once done.
  bool get canPreview => relPath != null && previewMimeType != null;
}

/// Appends staged upload paths to the outgoing prompt text. Every agent CLI
/// reads local paths with its own tools, so a plain-text reference works
/// uniformly across claude-code/codex/opencode.
String appendAttachmentPaths(String text, List<String> paths) {
  if (paths.isEmpty) return text;
  final block = paths.map((p) => 'Attached file: $p').join('\n');
  return text.isEmpty ? block : '$text\n\n$block';
}

/// Renders attachment rows above the composer's control strip. Pure widget:
/// all mutation goes through the callbacks.
class ComposerAttachmentChips extends StatelessWidget {
  const ComposerAttachmentChips({
    super.key,
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    this.onPreview,
  });

  final List<ComposerAttachment> attachments;
  final void Function(ComposerAttachment) onRemove;
  final void Function(ComposerAttachment) onRetry;

  /// Opens a preview. Only ever offered for an attachment the BRIDGE said it
  /// can render ([ComposerAttachment.canPreview]) — a chip with no viewer
  /// behind it stays inert rather than opening an error.
  final void Function(ComposerAttachment)? onPreview;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space10,
        AbTokens.space6,
        AbTokens.space10,
        0,
      ),
      child: Wrap(
        spacing: AbTokens.space8,
        runSpacing: AbTokens.space4,
        children: [
          for (final a in attachments)
            // Chip-sized row: the filename's type sets the height, not the
            // retry/remove glyphs beside it.
            AbCompactTapTargets(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AttachmentLabel(
                    attachment: a,
                    onPreview: a.status == AttachmentStatus.done && a.canPreview
                        ? onPreview
                        : null,
                  ),
                  const SizedBox(width: AbTokens.space4),
                  if (a.status == AttachmentStatus.error)
                    AbIconButton(
                      icon: AbIcons.refresh,
                      tooltip: 'Retry upload',
                      onTap: () => onRetry(a),
                    ),
                  AbIconButton(
                    icon: AbIcons.close,
                    tooltip: 'Remove attachment',
                    onTap: () => onRemove(a),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}


/// The thumbnail + filename half of a chip, tappable only when a preview
/// actually exists behind it.
class _AttachmentLabel extends StatelessWidget {
  const _AttachmentLabel({required this.attachment, this.onPreview});

  final ComposerAttachment attachment;
  final void Function(ComposerAttachment)? onPreview;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final a = attachment;
    final thumbnail = a.thumbnail;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (thumbnail != null) ...[
          ClipRRect(
            borderRadius: AbTokens.borderRadius3,
            child: Image.memory(
              thumbnail,
              width: _kThumbnailExtent,
              height: _kThumbnailExtent,
              fit: BoxFit.cover,
              // The still is already decoded at its display size; letting
              // Flutter re-scale it on every rebuild would undo that.
              filterQuality: FilterQuality.medium,
            ),
          ),
          const SizedBox(width: AbTokens.space6),
        ],
        Text(
          switch (a.status) {
            AttachmentStatus.uploading =>
              '${a.fileName} ${(a.progress * 100).round()}%',
            AttachmentStatus.done => a.fileName,
            AttachmentStatus.error => '${a.fileName} — failed',
          },
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXs,
            color: switch (a.status) {
              AttachmentStatus.error => p.error,
              AttachmentStatus.done => p.textSecondary,
              AttachmentStatus.uploading => p.textMuted,
            },
          ),
        ),
      ],
    );
    final onPreview = this.onPreview;
    if (onPreview == null) return label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onPreview(a),
        behavior: HitTestBehavior.opaque,
        child: label,
      ),
    );
  }
}

/// Square side of a chip thumbnail, in logical pixels.
const double _kThumbnailExtent = 18;
