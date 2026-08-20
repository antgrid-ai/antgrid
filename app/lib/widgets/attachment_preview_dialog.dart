import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../providers/providers.dart';
import '../services/file_service.dart';
import 'file_viewer_router.dart';

/// Opens a preview of a staged attachment over the composer.
///
/// Reuses the Files tab's whole read path — the same `file:read` verb (which
/// reaches `.antgrid/uploads/` because `readFile` applies no ignore list) and
/// the same [FileViewerRouter], so "which types can be previewed" is answered
/// once, by the bridge, for both surfaces. Only the RESPONSE SLOT differs
/// ([FileService.openPreview]): routing this through the Files pane would evict
/// whatever file the user has open in the context panel.
///
/// [relPath] must be the project-relative path from `file:upload-result` —
/// `file:read` accepts no other form, and the app never learns the checkout
/// root.
Future<void> showAttachmentPreview(
  BuildContext context,
  ProviderContainer container, {
  required String relPath,
  required String displayName,
}) async {
  final service = focusedServiceOrNull<FileService>(
    container,
    (s) => s.fileService,
  );
  if (service == null) return;
  service.openPreview(relPath, displayName: displayName);
  try {
    await showDialog<void>(
      context: context,
      builder: (context) => const _AttachmentPreviewDialog(),
    );
  } finally {
    // Also runs when the barrier or system back dismissed the dialog, which
    // never reaches the viewer's own close button — leaving the slot open would
    // keep re-reading the file on every reconnect.
    service.closePreview();
  }
}

class _AttachmentPreviewDialog extends ConsumerWidget {
  const _AttachmentPreviewDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.antgrid;
    final preview = ref
        .watch(fileTreeStateProvider)
        .value
        ?.preview;
    return Dialog(
      insetPadding: const EdgeInsets.all(AbTokens.space16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.borderSubtle),
            borderRadius: AbTokens.borderRadius8,
          ),
          child: ClipRRect(
            borderRadius: AbTokens.borderRadius8,
            child: FileViewerRouter(
              fileContent: preview?.content,
              // Null state means the service went away under us (project
              // evicted mid-preview); the router's loading branch is the honest
              // rendering of "nothing to show yet", not an error.
              isLoading: preview?.isLoading ?? true,
              selectedFilePath: preview?.displayName ?? preview?.path,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
  }
}
