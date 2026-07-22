import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon_button.dart';

enum AttachmentStatus { uploading, done, error }

/// One file attached to the composer. Mutable: the owning widget updates
/// status/progress in setState as the upload advances.
class ComposerAttachment {
  ComposerAttachment({required this.fileName, required this.bytes});

  final String fileName;

  /// Kept until the upload succeeds so an error chip can retry without
  /// re-picking; nulled on success to release up to 20 MB promptly.
  Uint8List? bytes;

  AttachmentStatus status = AttachmentStatus.uploading;
  double progress = 0;
  String? path;
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
  });

  final List<ComposerAttachment> attachments;
  final void Function(ComposerAttachment) onRemove;
  final void Function(ComposerAttachment) onRetry;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final p = context.antgrid;
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
        ],
      ),
    );
  }
}
