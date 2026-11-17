import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart'
    show Material, MaterialType, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_carbon.dart';
import '../models/device_stats.dart' show formatBytes;
import '../models/file_tree_models.dart';
import '../providers/providers.dart';
import '../services/file_service.dart';
import '../util/detached.dart';
import 'copy_path.dart';
import 'file_download.dart';
import 'file_viewer_kind.dart';
import 'file_viewer_router.dart';
import 'viewer_header.dart';
import 'viewer_support.dart';

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

/// The file preview popup: a title bar that says what is open and where it
/// lives, over the viewer for its type.
///
/// Sized to the screen rather than to a fixed box — a phone gets nearly the
/// whole screen, a desktop window a large panel — because a PDF page or a long
/// source file is the content here, and a 900x720 cap left most of a big
/// display unused while overflowing a small one.
///
/// Callers open it with a plain dialog route from Ab surfaces, so it carries
/// its own Carbon scope at the route root.
class AttachmentPreviewDialog extends StatelessWidget {
  const AttachmentPreviewDialog({super.key, required this.service});

  final FileService service;

  @override
  Widget build(BuildContext context) => Material(
    // Above the scope: a Material inside it would replace the Carbon text
    // style. A dialog route has no Material ancestor, which the viewers' text
    // selection and the not yet migrated media viewers expect.
    type: MaterialType.transparency,
    child: AbCarbonScope(
      child: StreamBuilder<FileTreeState>(
        stream: service.stateStream,
        initialData: service.currentState,
        builder: (context, snapshot) => _buildPreview(context, snapshot.data!),
      ),
    ),
  );

  Widget _buildPreview(BuildContext context, FileTreeState state) {
    final colors = CarbonTheme.of(context).colors;
    final preview = state.preview;
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < kCompactBreakpoint;
    final inset = compact ? CarbonSpacing.spacing03 : CarbonSpacing.spacing06;
    final maxWidth = screen.width - inset * 2;
    final maxHeight =
        screen.height - inset * 2 - MediaQuery.viewPaddingOf(context).vertical;
    final width = compact
        ? maxWidth
        : (screen.width * 0.82).clamp(560.0, 1120.0).clamp(0.0, maxWidth);
    final height = compact
        ? maxHeight
        : (screen.height * 0.86).clamp(420.0, 900.0).clamp(0.0, maxHeight);
    void close() => Navigator.of(context).pop();
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: colors.borderSubtle01),
          ),
          child: ColoredBox(
            color: colors.background,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PreviewTitleBar(
                  path: preview.path,
                  displayName: preview.displayName,
                  content: preview.content,
                  onClose: close,
                ),
                Expanded(
                  child: ViewerChrome(
                    child: FileViewerRouter(
                      fileContent: preview.content,
                      isLoading: preview.isLoading,
                      selectedFilePath: preview.displayName ?? preview.path,
                      onClose: close,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewTitleBar extends StatelessWidget {
  const _PreviewTitleBar({
    required this.path,
    required this.displayName,
    required this.content,
    required this.onClose,
  });

  final String? path;
  final String? displayName;
  final FileContent? content;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final loaded = content;
    final fullPath = loaded?.path ?? path ?? '';
    final name = displayName ?? previewFileName(fullPath);
    final folder = previewFolder(fullPath);
    final facts = loaded == null || loaded.error != null
        ? null
        : '${previewKindLabel(loaded)} · ${formatBytes(loaded.size)}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.layer01,
        border: Border(bottom: BorderSide(color: colors.borderSubtle01)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CarbonSpacing.spacing03,
          vertical: CarbonSpacing.spacing02,
        ),
        child: Row(
          spacing: CarbonSpacing.spacing02,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: CarbonSpacing.spacing02),
              child: CarbonIcon(
                loaded == null ? CarbonIcons.document : previewKindIcon(loaded),
                color: colors.iconSecondary,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.code.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (facts != null || folder.isNotEmpty)
                    // One line that gives up its folder first: two Row
                    // children would each need their own overflow rule.
                    Text.rich(
                      TextSpan(
                        children: [
                          if (facts != null) TextSpan(text: facts),
                          if (facts != null && folder.isNotEmpty)
                            const TextSpan(text: ' · '),
                          if (folder.isNotEmpty) TextSpan(text: folder),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.helper.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (fullPath.isNotEmpty)
              ViewerIconButton(
                icon: CarbonIcons.copy,
                label: 'Copy path',
                onPressed: () => detached(
                  'AttachmentPreview',
                  'copy path',
                  () => copyPathWithToast(context, fullPath),
                ),
              ),
            if (loaded != null) FileDownloadButton(content: loaded),
            ViewerIconButton(
              icon: CarbonIcons.close,
              label: 'Close',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The last segment of [path] under either separator: the path may name a file
/// on a machine running another OS than this one.
@visibleForTesting
String previewFileName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// [path] without its file name, in the separator style it was written in;
/// empty for a bare name.
@visibleForTesting
String previewFolder(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  if (cut <= 0) return '';
  final folder = path.substring(0, cut);
  return RegExp(r'^[A-Za-z]:$').hasMatch(folder)
      ? '$folder${path[cut]}'
      : folder;
}

/// What the viewer will show this as: `Markdown`, `PDF`, a source file's
/// extension (`JSON`, `DART`), or `Text` when it has none.
@visibleForTesting
String previewKindLabel(FileContent content) {
  switch (fileViewerKindFor(content.path, content.encoding, content.mimeType)) {
    case FileViewerKind.markdown:
      return 'Markdown';
    case FileViewerKind.svg:
      return 'SVG';
    case FileViewerKind.image:
      return 'Image';
    case FileViewerKind.pdf:
      return 'PDF';
    case FileViewerKind.binary:
      return 'Binary';
    case FileViewerKind.code:
      final name = previewFileName(content.path);
      final dot = name.lastIndexOf('.');
      return dot <= 0 || dot == name.length - 1
          ? 'Text'
          : name.substring(dot + 1).toUpperCase();
  }
}

@visibleForTesting
CarbonIcons previewKindIcon(FileContent content) {
  switch (fileViewerKindFor(content.path, content.encoding, content.mimeType)) {
    case FileViewerKind.image:
    case FileViewerKind.svg:
    case FileViewerKind.pdf:
      return CarbonIcons.view;
    case FileViewerKind.binary:
      return CarbonIcons.documentBlank;
    case FileViewerKind.markdown:
    case FileViewerKind.code:
      return CarbonIcons.document;
  }
}
