import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_text_field.dart';
import '../utils/platform_utils.dart';

/// What a tap or drag on the preview lays down.
enum PreviewDrawTool { pen, line, rect, ellipse, note }

/// One annotation, in the LIVE overlay's logical coordinates — the same space
/// the page is being displayed in, so a mark is stored exactly where the user
/// put it relative to what they were looking at. [paintPreviewMarks] is what
/// maps that into the captured screenshot's pixels at send time.
class PreviewDrawMark {
  PreviewDrawMark({
    required this.tool,
    required this.color,
    List<Offset>? points,
    this.text = '',
  }) : points = points ?? <Offset>[];

  final PreviewDrawTool tool;
  final Color color;

  /// Freehand: every sampled point. Line/rect/ellipse: exactly the two
  /// corners of the drag. Note: the single anchor it was placed at.
  final List<Offset> points;

  String text;
}

/// Stroke weight for every mark, in overlay-logical pixels. One weight, not a
/// picker: this is "circle the broken bit and send it", and a second row of
/// controls buys nothing an agent can read out of the result.
const double kPreviewDrawStrokeWidth = 3.0;

/// Type size for a note mark. Large enough to survive being scaled into a
/// full-resolution screenshot and read back by whoever opens the PNG.
const double kPreviewDrawNoteFontSize = AbTokens.fontLg;

/// A note wraps rather than running edge to edge, so it reads as a card and
/// not a banner across the screenshot.
const double kPreviewDrawNoteMaxWidth = 240.0;

const double kPreviewDrawNotePadding = AbTokens.space6;

/// Paints [marks] onto [canvas], scaling from overlay-logical coordinates to
/// whatever space the canvas is in. Shared by the on-screen painter (scale 1)
/// and the offscreen compositor in [compositePreviewMarks] (scale = captured
/// pixels per logical pixel), which is what guarantees the PNG the agent
/// receives is the drawing the user actually saw.
void paintPreviewMarks(
  Canvas canvas,
  List<PreviewDrawMark> marks,
  double scale,
) {
  for (final mark in marks) {
    if (mark.points.isEmpty) continue;
    final paint = Paint()
      ..color = mark.color
      ..strokeWidth = kPreviewDrawStrokeWidth * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    switch (mark.tool) {
      case PreviewDrawTool.pen:
        // A tap that never moved is still a mark the user made — draw it as
        // the dot it looks like rather than dropping it for having one point.
        if (mark.points.length == 1) {
          canvas.drawCircle(
            mark.points.first * scale,
            kPreviewDrawStrokeWidth * scale / 2,
            Paint()..color = mark.color,
          );
          break;
        }
        final path = Path()
          ..moveTo(mark.points.first.dx * scale, mark.points.first.dy * scale);
        for (final point in mark.points.skip(1)) {
          path.lineTo(point.dx * scale, point.dy * scale);
        }
        canvas.drawPath(path, paint);
      case PreviewDrawTool.line:
        if (mark.points.length < 2) break;
        canvas.drawLine(
          mark.points.first * scale,
          mark.points.last * scale,
          paint,
        );
      case PreviewDrawTool.rect:
        if (mark.points.length < 2) break;
        canvas.drawRect(_scaledBounds(mark, scale), paint);
      case PreviewDrawTool.ellipse:
        if (mark.points.length < 2) break;
        canvas.drawOval(_scaledBounds(mark, scale), paint);
      case PreviewDrawTool.note:
        // Rendered as a small tinted card, not bare text laid over the page:
        // that's what reads as "an annotation left here" rather than as a
        // caption baked into the screenshot itself.
        if (mark.text.isEmpty) break;
        final painter = TextPainter(
          text: TextSpan(
            text: mark.text,
            style: AbTokens.sansStyle(
              fontSize: kPreviewDrawNoteFontSize * scale,
              color: mark.color,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: kPreviewDrawNoteMaxWidth * scale);
        final pad = kPreviewDrawNotePadding * scale;
        final cardRect = Rect.fromLTWH(
          mark.points.first.dx * scale,
          mark.points.first.dy * scale,
          painter.width + pad * 2,
          painter.height + pad * 2,
        );
        final cardRadius = Radius.circular(AbTokens.radius5 * scale);
        final card = RRect.fromRectAndRadius(cardRect, cardRadius);
        canvas.drawRRect(card, Paint()..color = mark.color.withValues(alpha: 0.16));
        canvas.drawRRect(
          card,
          Paint()
            ..color = mark.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * scale,
        );
        painter.paint(canvas, Offset(cardRect.left + pad, cardRect.top + pad));
    }
  }
}

Rect _scaledBounds(PreviewDrawMark mark, double scale) =>
    Rect.fromPoints(mark.points.first * scale, mark.points.last * scale);

/// Flattens [marks] onto [screenshot] at the screenshot's own resolution.
///
/// [overlaySize] is the size the marks were drawn in — the live preview's
/// box, which the capture is a pixel-for-pixel image of — so the width ratio
/// between the two is the only scale factor needed. Returns null if the
/// screenshot can't be decoded or encoded.
Future<Uint8List?> compositePreviewMarks({
  required Uint8List screenshot,
  required List<PreviewDrawMark> marks,
  required Size overlaySize,
}) async {
  if (marks.isEmpty) return screenshot;

  ui.Codec? codec;
  ui.Image? image;
  ui.Image? flattened;
  ui.Picture? picture;
  try {
    codec = await ui.instantiateImageCodec(screenshot);
    image = (await codec.getNextFrame()).image;
    final scale =
        overlaySize.width > 0 ? image.width / overlaySize.width : 1.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    paintPreviewMarks(canvas, marks, scale);
    picture = recorder.endRecording();
    flattened = await picture.toImage(image.width, image.height);
    final data = await flattened.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } on Object {
    return null;
  } finally {
    picture?.dispose();
    flattened?.dispose();
    image?.dispose();
    codec?.dispose();
  }
}

/// Draw-on-the-live-preview annotation layer: a transparent capture surface
/// sitting directly over the page, plus one floating tool bar.
///
/// Deliberately NOT a capture-then-annotate flow. Freezing the page into a
/// still and swapping it in for the live view costs a visible flicker and a
/// whole change of surface every time the pencil is pressed, for a step the
/// user never asked for — they want to circle something on the page in front
/// of them. So nothing is captured until [onSend]: the marks live in this
/// overlay's own coordinates, and only then is the viewport rasterized and
/// the drawing flattened onto it (see [compositePreviewMarks]).
///
/// The host (`preview_screen.dart`) supplies [captureScreenshot] and owns
/// uploading the flattened bytes and composing the agent message.
class PreviewDrawOverlay extends StatefulWidget {
  const PreviewDrawOverlay({
    super.key,
    required this.captureScreenshot,
    required this.onClose,
    required this.onSend,
  });

  /// Rasterizes the previewed page's current viewport, or null on failure.
  /// Called once, at send time.
  final Future<Uint8List?> Function() captureScreenshot;

  /// Called once the user has dismissed — after confirming, when there were
  /// marks to lose.
  final VoidCallback onClose;

  /// Called with the screenshot and the drawing flattened together as PNG.
  final ValueChanged<Uint8List> onSend;

  @override
  State<PreviewDrawOverlay> createState() => PreviewDrawOverlayState();
}

class PreviewDrawOverlayState extends State<PreviewDrawOverlay> {
  final List<PreviewDrawMark> _marks = [];
  final GlobalKey _canvasKey = GlobalKey();
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _noteFocus = FocusNode();

  PreviewDrawTool _tool = PreviewDrawTool.pen;
  Color? _color;
  bool _sending = false;

  /// Index into [_marks] of the note being typed into, or null. A note mark
  /// is created empty on tap and dropped again if nothing is typed, so this
  /// doubles as "an editor is open".
  int? _editing;

  @override
  void initState() {
    super.initState();
    // Committing on focus loss as well as on submit is what makes tapping
    // away from the field (onto the page, onto a tool) finish the note
    // instead of stranding an editor nothing will close.
    _noteFocus.addListener(() {
      if (!_noteFocus.hasFocus) _commitNote();
    });
  }

  @override
  void dispose() {
    _noteController.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  Color _penColor(BuildContext context) => _color ?? context.antgrid.error;

  Size get _canvasSize {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size ?? Size.zero;
  }

  /// Confines a point to the overlay's own box. A pan gesture keeps reporting
  /// [DragUpdateDetails.localPosition] — including well past the canvas
  /// edge, negative coordinates included — for as long as the drag stays
  /// alive, regardless of where the pointer actually is on screen. Since the
  /// preview sits directly beside the agent panel, an unclamped drag lets a
  /// stroke run off the browser and onto whatever's next to it. Marks are
  /// meant to live entirely inside the previewed page, so every recorded
  /// point is pinned back to it here rather than at paint time.
  Offset _clampToCanvas(Offset point) {
    final size = _canvasSize;
    if (size.isEmpty) return point;
    return Offset(
      point.dx.clamp(0.0, size.width),
      point.dy.clamp(0.0, size.height),
    );
  }

  void _startMark(Offset at, Color color) {
    final clamped = _clampToCanvas(at);
    setState(() {
      _marks.add(
        PreviewDrawMark(
          tool: _tool,
          color: color,
          points: _tool == PreviewDrawTool.pen ? [clamped] : [clamped, clamped],
        ),
      );
    });
  }

  void _extendMark(Offset to) {
    if (_marks.isEmpty) return;
    final clamped = _clampToCanvas(to);
    setState(() {
      final mark = _marks.last;
      if (mark.tool == PreviewDrawTool.pen) {
        mark.points.add(clamped);
      } else {
        mark.points[1] = clamped;
      }
    });
  }

  /// Drops a shape that never actually moved — a stray tap while a shape tool
  /// is selected would otherwise leave a zero-sized invisible mark behind
  /// that still counts as unsaved work at close time.
  void _endMark() {
    if (_marks.isEmpty) return;
    final mark = _marks.last;
    if (mark.tool == PreviewDrawTool.pen) return;
    if (mark.points.first == mark.points.last) {
      setState(_marks.removeLast);
    }
  }

  void _onTapUp(TapUpDetails details, Color color) {
    if (_editing != null) {
      // The open editor takes the tap: finishing what is being typed is what
      // a tap elsewhere means here, not laying down a second mark.
      _commitNote();
      return;
    }
    switch (_tool) {
      case PreviewDrawTool.note:
        setState(() {
          _marks.add(
            PreviewDrawMark(
              tool: PreviewDrawTool.note,
              color: color,
              points: [details.localPosition],
            ),
          );
          _editing = _marks.length - 1;
          _noteController.clear();
        });
        _noteFocus.requestFocus();
      case PreviewDrawTool.pen:
        _startMark(details.localPosition, color);
      case PreviewDrawTool.line:
      case PreviewDrawTool.rect:
      case PreviewDrawTool.ellipse:
        break;
    }
  }

  void _commitNote() {
    final index = _editing;
    if (index == null) return;
    final value = _noteController.text.trim();
    setState(() {
      _editing = null;
      if (value.isEmpty) {
        _marks.removeAt(index);
      } else {
        _marks[index].text = value;
      }
    });
    _noteController.clear();
  }

  /// Discards the note being typed outright, whatever it currently holds —
  /// unlike [_commitNote], which only drops it when empty. This is the
  /// explicit "never mind" the Escape key and the editor's close button use.
  void _cancelNote() {
    final index = _editing;
    if (index == null) return;
    setState(() {
      _editing = null;
      _marks.removeAt(index);
    });
    _noteController.clear();
    _noteFocus.unfocus();
  }

  void _undo() {
    if (_marks.isEmpty) return;
    _commitNote();
    if (_marks.isEmpty) return;
    setState(_marks.removeLast);
  }

  void _clear() {
    if (_marks.isEmpty) return;
    setState(() {
      _editing = null;
      _marks.clear();
    });
    _noteController.clear();
  }

  /// Dismissing is only cheap while there is nothing to lose: once marks
  /// exist, the close button sits one slip away from a drawing that cannot be
  /// recovered, which is exactly the case the confirm is for.
  ///
  /// Public so the host can route a system back gesture through the same
  /// guard instead of around it — see `preview_screen.dart`'s
  /// `_backFromPreview`.
  Future<void> requestClose() async {
    _commitNote();
    if (_marks.isEmpty) {
      widget.onClose();
      return;
    }
    final discard = await AbConfirmDialog.show(
      context: context,
      title: 'Discard drawing?',
      body: 'Your marks on this page will be lost.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep drawing',
      destructive: true,
    );
    if (!mounted || !discard) return;
    widget.onClose();
  }

  Future<void> _send() async {
    if (_sending) return;
    _commitNote();
    final size = _canvasSize;
    setState(() => _sending = true);
    try {
      final screenshot = await widget.captureScreenshot();
      if (screenshot == null || !mounted) return;
      final flattened = await compositePreviewMarks(
        screenshot: screenshot,
        marks: _marks,
        overlaySize: size,
      );
      if (flattened == null || !mounted) return;
      widget.onSend(flattened);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _penColor(context);
    return Stack(
      key: _canvasKey,
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('preview-draw-canvas'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _onTapUp(d, color),
            onPanStart: _tool == PreviewDrawTool.note
                ? null
                : (d) => _startMark(d.localPosition, color),
            onPanUpdate: _tool == PreviewDrawTool.note
                ? null
                : (d) => _extendMark(d.localPosition),
            onPanEnd: _tool == PreviewDrawTool.note ? null : (_) => _endMark(),
            // Belt-and-suspenders alongside the point clamping above: a
            // `CustomPaint` doesn't clip its own canvas by default, so
            // without this any point that slipped through un-clamped would
            // still paint over whatever sits outside the preview.
            child: ClipRect(
              child: CustomPaint(
                painter: _MarksPainter(_marks),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        if (_editing != null) _buildNoteEditor(color),
        Positioned(
          left: AbTokens.space8,
          right: AbTokens.space8,
          bottom: AbTokens.space12,
          child: Center(
            child: _DrawToolBar(
              tool: _tool,
              color: color,
              busy: _sending,
              hasMarks: _marks.isNotEmpty,
              onTool: (t) {
                _commitNote();
                setState(() => _tool = t);
              },
              onColor: (c) => setState(() => _color = c),
              onUndo: _undo,
              onClear: _clear,
              onClose: () => unawaited(requestClose()),
              onSend: () => unawaited(_send()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNoteEditor(Color color) {
    final anchor = _marks[_editing!].points.first;
    final size = _canvasSize;
    // Clamp so a mark placed near the right or bottom edge still opens a
    // fully visible field instead of one hanging off the panel.
    final left = size.width > 0
        ? anchor.dx.clamp(
            0.0,
            (size.width - _kNoteEditorWidth).clamp(0.0, size.width),
          )
        : anchor.dx;
    final top = size.height > 0
        ? anchor.dy.clamp(
            0.0,
            (size.height - AbTokens.rowHeightLg).clamp(0.0, size.height),
          )
        : anchor.dy;
    return Positioned(
      left: left,
      top: top,
      width: _kNoteEditorWidth,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _cancelNote();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AbTextField(
          controller: _noteController,
          focusNode: _noteFocus,
          hintText: 'Note',
          autofocus: true,
          // Tinted to match the color the note will render in, so the editor
          // already reads as the card it's about to become.
          fillColor: color.withValues(alpha: 0.12),
          suffix: AbIconButton(
            icon: AbIcons.close,
            tooltip: 'Cancel note',
            onTap: _cancelNote,
          ),
          onSubmitted: (_) => _commitNote(),
        ),
      ),
    );
  }
}

const double _kNoteEditorWidth = 220.0;

class _MarksPainter extends CustomPainter {
  const _MarksPainter(this.marks);

  final List<PreviewDrawMark> marks;

  @override
  void paint(Canvas canvas, Size size) => paintPreviewMarks(canvas, marks, 1);

  // Marks are mutated in place (same List instance every rebuild) so
  // identity/equality checks against the old delegate would never see a
  // change — repainting on every rebuild is cheap enough here to just always
  // do it rather than track a revision counter for this.
  @override
  bool shouldRepaint(covariant _MarksPainter oldDelegate) => true;
}

/// The floating bar: shape tools, then color, then the two ways out. Floats
/// over the page rather than docking above or below it, so arming the pencil
/// costs the preview no layout at all — nothing moves, nothing reflows, and
/// the page underneath is still exactly where it was.
class _DrawToolBar extends StatelessWidget {
  const _DrawToolBar({
    required this.tool,
    required this.color,
    required this.busy,
    required this.hasMarks,
    required this.onTool,
    required this.onColor,
    required this.onUndo,
    required this.onClear,
    required this.onClose,
    required this.onSend,
  });

  final PreviewDrawTool tool;
  final Color color;
  final bool busy;
  final bool hasMarks;
  final ValueChanged<PreviewDrawTool> onTool;
  final ValueChanged<Color> onColor;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final VoidCallback onSend;

  static const _tools = <(PreviewDrawTool, String, String)>[
    (PreviewDrawTool.pen, AbIcons.draw, 'Freehand'),
    (PreviewDrawTool.line, AbIcons.drawLine, 'Line'),
    (PreviewDrawTool.rect, AbIcons.drawRect, 'Rectangle'),
    (PreviewDrawTool.ellipse, AbIcons.drawEllipse, 'Ellipse'),
    (PreviewDrawTool.note, AbIcons.comment, 'Note'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = [
      context.antgrid.error,
      context.antgrid.warning,
      context.antgrid.success,
      context.antgrid.accent,
      context.antgrid.textPrimary,
    ];
    return Container(
      height: isMobilePlatform ? AbTokens.rowHeightXl : AbTokens.rowHeightLg,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
      decoration: BoxDecoration(
        color: context.antgrid.bgSurface,
        border: Border.all(color: context.antgrid.borderDefault),
        borderRadius: AbTokens.borderRadiusFull,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only the tool cluster scrolls, and the two ways out are pinned
          // outside it: a dozen cells cannot fit a phone-width panel, and the
          // one control that must never be scrolled off is the one that gets
          // you out of a mode covering the whole page.
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (kind, icon, label) in _tools)
                    _BarCell(
                      tooltip: label,
                      selected: kind == tool,
                      onTap: () => onTool(kind),
                      child: AbIcon(
                        icon,
                        size: AbTokens.iconButtonGlyph,
                        color: kind == tool
                            ? context.antgrid.accent
                            : context.antgrid.textSecondary,
                      ),
                    ),
                  const _BarDivider(),
                  for (final swatch in palette)
                    _BarCell(
                      tooltip: 'Pen color',
                      selected: swatch == color,
                      onTap: () => onColor(swatch),
                      child: Container(
                        width: AbTokens.space16,
                        height: AbTokens.space16,
                        decoration: BoxDecoration(
                          color: swatch,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: context.antgrid.borderStrong,
                          ),
                        ),
                      ),
                    ),
                  const _BarDivider(),
                  _BarCell(
                    tooltip: 'Undo',
                    selected: false,
                    onTap: hasMarks ? onUndo : null,
                    child: AbIcon(
                      AbIcons.undo,
                      size: AbTokens.iconButtonGlyph,
                      color: hasMarks
                          ? context.antgrid.textSecondary
                          : context.antgrid.textDisabled,
                    ),
                  ),
                  _BarCell(
                    tooltip: 'Clear',
                    selected: false,
                    onTap: hasMarks ? onClear : null,
                    child: AbIcon(
                      AbIcons.trash,
                      size: AbTokens.iconButtonGlyph,
                      color: hasMarks
                          ? context.antgrid.textSecondary
                          : context.antgrid.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const _BarDivider(),
          _BarCell(
            tooltip: 'Close',
            selected: false,
            onTap: onClose,
            child: AbIcon(
              AbIcons.close,
              size: AbTokens.iconButtonGlyph,
              color: context.antgrid.textSecondary,
            ),
          ),
          const SizedBox(width: AbTokens.space6),
          AbButton(
            label: busy ? 'Sending…' : 'Send',
            variant: AbButtonVariant.primary,
            onTap: busy ? null : onSend,
          ),
        ],
      ),
    );
  }
}

class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: AbTokens.space6),
    child: SizedBox(
      height: AbTokens.space16,
      child: AbSeparator.vertical(weight: AbSeparatorWeight.strong),
    ),
  );
}

/// A bar cell: a fixed square target around whatever glyph or swatch it
/// holds, with selection shown as a ring on the CELL — the swatches differ
/// only in color, so there is nothing on them to latch.
class _BarCell extends StatelessWidget {
  const _BarCell({
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final edge = isMobilePlatform
        ? AbTokens.tapTargetMin - AbTokens.space8
        : AbTokens.rowHeightXs;
    return Semantics(
      button: true,
      label: tooltip,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: Container(
            width: edge,
            height: edge,
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    color: context.antgrid.bgElevated,
                    shape: BoxShape.circle,
                    border: Border.all(color: context.antgrid.borderStrong),
                  )
                : null,
            child: child,
          ),
        ),
      ),
    );
  }
}
