import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../models/file_tree_models.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/value_controller.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import 'pdf_scrollbar.dart';
import 'viewer_header.dart';
import 'viewer_support.dart';

/// Renders a PDF from base64 content using pdfrx (native PDFium).
///
/// Named `FilePdfViewer` (not `PdfViewer`) to avoid colliding with pdfrx's own
/// exported `PdfViewer` widget, which this file references.
class FilePdfViewer extends StatefulWidget {
  final FileContent content;
  final VoidCallback? onClose;

  const FilePdfViewer({super.key, required this.content, this.onClose});

  @override
  State<FilePdfViewer> createState() => _FilePdfViewerState();
}

class _FilePdfViewerState extends State<FilePdfViewer> {
  final _controller = PdfViewerController();
  // Resolved on first use: a PDF that never becomes ready (bad bytes) never
  // touches the pager, and needs no ProviderScope above it.
  ProviderContainer? _container;
  ValueController<bool>? _pagerLock;

  PdfViewerParams? _params;
  Color? _paramsBackground;

  // Held in state so a rebuild hands pdfrx an equal params object; a fresh
  // closure each build would make it treat the viewer as reconfigured. Only a
  // theme change rebuilds it.
  PdfViewerParams _paramsFor(Color background) {
    if (_params == null || _paramsBackground != background) {
      _paramsBackground = background;
      _params = PdfViewerParams(
        // pdfrx's default grey is the scrollbar thumb's own colour, which
        // hides the thumb between pages.
        backgroundColor: background,
        linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLinkTap),
        viewerOverlayBuilder: _overlay,
        errorBannerBuilder: _errorBanner,
      );
    }
    return _params!;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncPagerLock);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncPagerLock);
    // Providers can't be written while the tree is being torn down.
    final lock = _pagerLock;
    if (lock != null) scheduleMicrotask(() => lock.set(false));
    super.dispose();
  }

  /// While zoomed, a horizontal drag has to pan the page: the phone's pager
  /// claims it at the touch slop, before pdfrx's own recognizer would. At fit
  /// zoom the pager is free again, so a swipe still reaches the agent.
  void _syncPagerLock() {
    if (!_controller.isReady) return;
    final ProviderContainer container =
        _container ?? ProviderScope.containerOf(context, listen: false);
    final ValueController<bool> lock =
        _pagerLock ?? container.read(pagerSwipeLockedProvider.notifier);
    _container = container;
    _pagerLock = lock;
    final zoomed = _controller.currentZoom > _controller.coverScale * 1.02;
    if (zoomed == container.read(pagerSwipeLockedProvider)) return;
    scheduleMicrotask(() => lock.set(zoomed));
  }

  List<Widget> _overlay(
    BuildContext context,
    Size size,
    PdfViewerHandleLinkTap handleLinkTap,
  ) {
    return [
      PdfScrollbar(controller: _controller),
      PdfScrollbar(controller: _controller, axis: Axis.horizontal),
      Positioned(
        right: AbTokens.space16,
        bottom: AbTokens.space16,
        child: _ZoomControls(controller: _controller),
      ),
    ];
  }

  Widget _errorBanner(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
    PdfDocumentRef documentRef,
  ) {
    final c = context.antgrid;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AbTokens.space16),
        child: Text(
          'Could not open PDF: $error',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: c.textMuted),
        ),
      ),
    );
  }

  void _onLinkTap(PdfLink link) {
    final url = link.url;
    if (url != null) {
      // A PDF is untrusted content: only web schemes may reach the OS launcher.
      final target = openableTerminalHyperlink(url.toString());
      if (target != null) {
        detached(
          'FilePdfViewer',
          'open link',
          () => openExternalUrl(context, target.toString()),
        );
      }
      return;
    }
    final dest = link.dest;
    if (dest != null) {
      detached('FilePdfViewer', 'go to destination', () async {
        await _controller.goToDest(dest);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildViewerHeader(content: widget.content, onClose: widget.onClose),
        Expanded(
          child: Container(
            color: c.bgDeepest,
            child: DecodedBytesBuilder(
              content: widget.content,
              builder: (context, bytes) => bytes == null
                  ? Center(
                      child: Text(
                        "Couldn't render this PDF",
                        style: AbTokens.sansStyle(color: c.textMuted),
                      ),
                    )
                  : PdfViewer.data(
                      bytes,
                      sourceName: widget.content.path,
                      controller: _controller,
                      params: _paramsFor(c.bgDeepest),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ZoomControls extends StatelessWidget {
  final PdfViewerController controller;

  const _ZoomControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Container(
      padding: const EdgeInsets.all(AbTokens.space4),
      decoration: BoxDecoration(
        color: c.bgSurface,
        border: Border.all(color: c.borderDefault),
        borderRadius: BorderRadius.circular(AbTokens.radius5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbIconButton(
            icon: AbIcons.zoomOut,
            tooltip: 'Zoom out',
            onTap: () => detached(
              'FilePdfViewer',
              'zoom out',
              () => controller.zoomDown(),
            ),
          ),
          AbIconButton(
            icon: AbIcons.zoomIn,
            tooltip: 'Zoom in',
            onTap: () => detached(
              'FilePdfViewer',
              'zoom in',
              () => controller.zoomUp(),
            ),
          ),
        ],
      ),
    );
  }
}
