import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

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
        right: CarbonSpacing.spacing05,
        bottom: CarbonSpacing.spacing05,
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
    return ViewerErrorNotice(message: 'Could not open PDF: $error');
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
    final background = CarbonTheme.of(context).colors.background;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildViewerHeader(content: widget.content, onClose: widget.onClose),
        Expanded(
          child: ColoredBox(
            color: background,
            child: DecodedBytesBuilder(
              content: widget.content,
              builder: (context, bytes) => bytes == null
                  ? const ViewerErrorNotice(
                      message: "Couldn't render this PDF",
                    )
                  : PdfViewer.data(
                      bytes,
                      sourceName: widget.content.path,
                      controller: _controller,
                      params: _paramsFor(background),
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
    final colors = CarbonTheme.of(context).colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.layer01,
        border: Border.all(color: colors.borderSubtle01),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ViewerIconButton(
            icon: CarbonIcons.zoomOut,
            label: 'Zoom out',
            onPressed: () => detached(
              'FilePdfViewer',
              'zoom out',
              () => controller.zoomDown(),
            ),
          ),
          ViewerIconButton(
            icon: CarbonIcons.zoomIn,
            label: 'Zoom in',
            onPressed: () => detached(
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
