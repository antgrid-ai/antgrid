import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../models/file_tree_models.dart';
import '../providers/providers.dart';
import '../services/file_service.dart';
import 'file_viewer_router.dart';

/// Opens a preview dialog over [service]'s `openPreview` slot for [path] —
/// the shared mechanism behind both callers below. Reuses the Files tab's
/// whole read path (the same `file:read` verb and the same
/// [FileViewerRouter]), so "which types can be previewed" is answered once,
/// by the bridge, for every surface that calls this. Only the RESPONSE SLOT
/// differs from the Files tab ([FileService.openPreview]): routing either
/// caller's path through the Files pane would evict whatever file the user
/// has open in the context panel.
///
/// [service] is passed in rather than resolved here because the two callers
/// need it scoped differently: [showAttachmentPreview] wants the FOCUSED
/// project's (an upload always targets it), while a terminal hyperlink's
/// [FileService] must come from that terminal's OWN checkout, which is not
/// always the focused one.
Future<void> showFilePreviewDialog(
  BuildContext context,
  FileService service, {
  required String path,
  required String displayName,
}) async {
  service.openPreview(path, displayName: displayName);
  try {
    await showDialog<void>(
      context: context,
      builder: (context) => AttachmentPreviewDialog(service: service),
    );
  } finally {
    // Also runs when the barrier or system back dismissed the dialog, which
    // never reaches the viewer's own close button — leaving the slot open would
    // keep re-reading the file on every reconnect.
    service.closePreview();
  }
}

/// Opens a preview of a staged attachment over the composer.
///
/// [relPath] must be the project-relative path from `file:upload-result` —
/// `file:read` accepts no other form (for THIS caller — see
/// [showFilePreviewDialog] for the one exception, an external image a
/// terminal hyperlink named), and the app never learns the checkout root.
/// Resolves [FileService] from the FOCUSED project, since an upload is
/// always staged there.
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
  await showFilePreviewDialog(
    context,
    service,
    path: relPath,
    displayName: displayName,
  );
}

class AttachmentPreviewDialog extends StatelessWidget {
  const AttachmentPreviewDialog({super.key, required this.service});

  final FileService service;

  @override
  Widget build(BuildContext context) => StreamBuilder<FileTreeState>(
    stream: service.stateStream,
    initialData: service.currentState,
    builder: (context, snapshot) => _buildPreview(context, snapshot.data!),
  );

  Widget _buildPreview(BuildContext context, FileTreeState state) {
    final colors = context.antgrid;
    final preview = state.preview;
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
              fileContent: preview.content,
              isLoading: preview.isLoading,
              selectedFilePath: preview.displayName ?? preview.path,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
  }
}
