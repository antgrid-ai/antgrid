import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_progress_rule.dart';
import 'terminal_attachment_uploader.dart';

/// The in-flight attach readout, shaped as a twin of `SendToAgentButton` so the
/// terminal's floating overlays read as one family.
///
/// [IgnorePointer] by construction: it floats over live terminal text, and a
/// tap target there would compete with drag-selection for the same pixels.
class TerminalUploadStrip extends StatelessWidget {
  const TerminalUploadStrip({super.key, required this.progress});

  final AttachProgress progress;

  /// Wide enough for a typical file name at [AbTokens.fontXs] without letting
  /// a long one push the strip across the terminal it overlays.
  static const double _width = 176;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final done = progress.phase == AttachPhase.done;
    final tint = done ? p.success : p.accent;
    return IgnorePointer(
      child: Container(
        width: _width,
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space10,
          vertical: AbTokens.space6,
        ),
        decoration: BoxDecoration(
          color: p.bgElevated,
          borderRadius: AbTokens.borderRadius5,
          border: Border.all(color: tint.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AbIcon(
                  done ? AbIcons.check : AbIcons.upload,
                  size: 12,
                  color: tint,
                ),
                const SizedBox(width: AbTokens.space4),
                Expanded(
                  child: Text(
                    _label(progress),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // Mono: the label names a file that becomes a path.
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AbTokens.space6),
            AbProgressRule(fraction: done ? 1.0 : progress.fraction),
          ],
        ),
      ),
    );
  }
}

String _label(AttachProgress progress) {
  final name = progress.fileName;
  return switch (progress.phase) {
    AttachPhase.staging => '$name · uploading…',
    // Matches the composer's attachment convention character for character.
    AttachPhase.sending => '$name ${((progress.fraction ?? 0) * 100).round()}%',
    AttachPhase.finishing => '$name · finishing…',
    AttachPhase.done => '$name · added',
  };
}
