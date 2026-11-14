import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import '../design/ab_carbon.dart';
import '../design/ab_tokens.dart';
import 'carbon_confirm.dart';

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
double get kPreviewDrawNoteFontSize => AbTokens.fontLg;

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
        canvas.drawRRect(
          card,
          Paint()..color = mark.color.withValues(alpha: 0.16),
        );
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
    final scale = overlaySize.width > 0 ? image.width / overlaySize.width : 1.0;
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

/// The pen palette. Held as a choice rather than a [Color] so a palette or
/// brightness switch re-resolves the selected swatch instead of leaving the
/// bar pointing at a colour that is no longer in it.
enum _PenColor {
  red('Red'),
  yellow('Yellow'),
  green('Green'),
  blue('Blue'),
  contrast('Contrast');

  const _PenColor(this.label);

  final String label;

  Color resolve(CarbonColors colors) => switch (this) {
    _PenColor.red => colors.supportError,
    _PenColor.yellow => colors.supportWarning,
    _PenColor.green => colors.supportSuccess,
    _PenColor.blue => colors.interactive,
    _PenColor.contrast => colors.textPrimary,
  };
}

class PreviewDrawOverlayState extends State<PreviewDrawOverlay> {
  final List<PreviewDrawMark> _marks = [];
  final GlobalKey _canvasKey = GlobalKey();

  /// A context under the Carbon scope, for presenting the discard modal: this
  /// State's own context sits above the scope and would hand the modal no
  /// Carbon theme.
  final GlobalKey _scopedKey = GlobalKey();
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _noteFocus = FocusNode();

  /// Holds primary focus for the overlay so Ctrl+Z (Cmd+Z on macOS) reaches
  /// [_undo] the same way the toolbar button does. The note editor's own
  /// [FocusNode] takes it over the moment a note is opened, same as any
  /// other descendant focus.
  final FocusNode _overlayFocus = FocusNode(debugLabel: 'PreviewDrawOverlay');

  PreviewDrawTool _tool = PreviewDrawTool.pen;
  _PenColor _pen = _PenColor.red;
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
    // `autofocus` on the Focus widget below only wins when nothing else in
    // the scope is already focused — the address bar (or whatever the user
    // last touched before arming the pencil) is still mounted underneath and
    // usually still holds it, which is what left Ctrl+Z with nowhere to
    // land. An explicit request, once the overlay is actually in the tree,
    // forces it over regardless of who had it before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _overlayFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _noteController.dispose();
    _noteFocus.dispose();
    _overlayFocus.dispose();
    super.dispose();
  }

  /// Ctrl+Z (Cmd+Z on macOS) undoes the last mark, mirroring the toolbar
  /// button. Shift is excluded so a future redo shortcut (Ctrl+Shift+Z) has
  /// somewhere to land without this swallowing it first.
  KeyEventResult _onOverlayKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.keyZ) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed) return KeyEventResult.ignored;
    final isUndoModifier = keys.isControlPressed || keys.isMetaPressed;
    if (!isUndoModifier) return KeyEventResult.ignored;
    _undo();
    return KeyEventResult.handled;
  }

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
    // Hand primary focus back to the overlay so Ctrl+Z keeps reaching
    // [_undo] once the note editor's own FocusNode gives it up — nothing
    // else on this surface claims focus on its own.
    _overlayFocus.requestFocus();
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
    _overlayFocus.requestFocus();
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
    final scoped = _scopedKey.currentContext;
    if (scoped == null) return;
    final discard = await showCarbonConfirm(
      scoped,
      title: 'Discard drawing?',
      body: 'Your marks on this page will be lost.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep drawing',
      danger: true,
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
    return Focus(
      focusNode: _overlayFocus,
      autofocus: true,
      onKeyEvent: _onOverlayKey,
      // One scope at a fixed position: the bar, the note editor and the
      // discard modal's presenting context all need the same Carbon theme,
      // and the canvas between them builds no Carbon widget.
      child: AbCarbonScope(
        child: Builder(
          key: _scopedKey,
          builder: (scoped) {
            final theme = CarbonTheme.of(scoped);
            final color = _pen.resolve(theme.colors);
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
                    onPanEnd: _tool == PreviewDrawTool.note
                        ? null
                        : (_) => _endMark(),
                    // Belt-and-suspenders alongside the point clamping above:
                    // a `CustomPaint` doesn't clip its own canvas by default,
                    // so without this any point that slipped through
                    // un-clamped would still paint over whatever sits outside
                    // the preview.
                    child: ClipRect(
                      child: CustomPaint(
                        painter: _MarksPainter(_marks),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                if (_editing != null) _buildNoteEditor(theme, color),
                Positioned(
                  left: CarbonSpacing.spacing03,
                  right: CarbonSpacing.spacing03,
                  bottom: CarbonSpacing.spacing04,
                  child: Center(
                    child: _DrawToolBar(
                      tool: _tool,
                      pen: _pen,
                      busy: _sending,
                      hasMarks: _marks.isNotEmpty,
                      onTool: (t) {
                        _commitNote();
                        setState(() => _tool = t);
                      },
                      onPen: (p) => setState(() => _pen = p),
                      onUndo: _undo,
                      onClear: _clear,
                      onClose: () => unawaited(requestClose()),
                      onSend: () => unawaited(_send()),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildNoteEditor(CarbonThemeData theme, Color color) {
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
            (size.height - theme.controlHeight).clamp(0.0, size.height),
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
        child: CarbonTextInput(
          controller: _noteController,
          focusNode: _noteFocus,
          placeholder: 'Note',
          semanticLabel: 'Note text',
          autofocus: true,
          // The colour the note will render in, since the field itself cannot
          // be tinted to match.
          prefix: _Swatch(color: color),
          // A field action, not a bare button: its tap counts as inside the
          // field, so a mouse press cannot blur-commit the note before Cancel
          // discards it.
          suffix: CarbonFieldAction(
            icon: const CarbonIcon(CarbonIcons.close),
            semanticLabel: 'Cancel note',
            onPressed: _cancelNote,
          ),
          onSubmitted: (_) => _commitNote(),
        ),
      ),
    );
  }
}

const double _kNoteEditorWidth =
    CarbonSpacing.spacing13 + CarbonSpacing.spacing10;

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

/// A round colour chip: the pen colour in the bar's picker button, the
/// palette's entries and the note editor's prefix.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return SizedBox.square(
      dimension: CarbonSpacing.spacing04,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: colors.borderStrong01),
        ),
      ),
    );
  }
}

/// The floating bar: shape tools, then color, then the two ways out. Floats
/// over the page rather than docking above or below it, so arming the pencil
/// costs the preview no layout at all — nothing moves, nothing reflows, and
/// the page underneath is still exactly where it was.
class _DrawToolBar extends StatelessWidget {
  const _DrawToolBar({
    required this.tool,
    required this.pen,
    required this.busy,
    required this.hasMarks,
    required this.onTool,
    required this.onPen,
    required this.onUndo,
    required this.onClear,
    required this.onClose,
    required this.onSend,
  });

  final PreviewDrawTool tool;
  final _PenColor pen;
  final bool busy;
  final bool hasMarks;
  final ValueChanged<PreviewDrawTool> onTool;
  final ValueChanged<_PenColor> onPen;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final VoidCallback onSend;

  static const _tools = <(PreviewDrawTool, CarbonIcons, String)>[
    (PreviewDrawTool.pen, CarbonIcons.draw, 'Freehand'),
    // Thin, not thick: at the icon size a thick stroke reads as a bar.
    (PreviewDrawTool.line, CarbonIcons.lineThin, 'Line'),
    (PreviewDrawTool.rect, CarbonIcons.squareOutline, 'Rectangle'),
    (PreviewDrawTool.ellipse, CarbonIcons.circleOutline, 'Ellipse'),
    (PreviewDrawTool.note, CarbonIcons.chat, 'Note'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: theme.colors.shadow,
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CarbonLayerSurface(
        border: true,
        padding: const EdgeInsets.symmetric(
          horizontal: CarbonSpacing.spacing03,
          vertical: CarbonSpacing.spacing02,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => _buildRow(
            // Send's label is the widest pinned control; below this width it
            // gives way to an icon so the tools keep a usable viewport.
            compact: constraints.maxWidth < _kCompactBarWidth,
          ),
        ),
      ),
    );
  }

  Widget _buildRow({required bool compact}) {
    return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Only the tool/color cluster scrolls. Undo, Clear and the two ways
            // out are all pinned outside it: a dozen cells cannot fit a
            // phone-width panel, and a control someone needs to reach every
            // time they overdraw must never be the one that scrolls out of
            // view — that used to include Undo/Clear, which is exactly the bug
            // this pinning fixes (they were reachable only by swiping the
            // toolbar itself, and read as simply missing).
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CarbonContentSwitcher<PreviewDrawTool>(
                      size: CarbonContentSwitcherSize.small,
                      iconOnly: true,
                      semanticLabel: 'Drawing tools',
                      value: tool,
                      onChanged: onTool,
                      options: [
                        for (final (kind, icon, label) in _tools)
                          CarbonOption<PreviewDrawTool>(
                            value: kind,
                            label: label,
                            icon: CarbonIcon(icon),
                          ),
                      ],
                    ),
                    const _BarDivider(),
                    _ColorPickerCell(pen: pen, onPen: onPen),
                  ],
                ),
              ),
            ),
            const _BarDivider(),
            CarbonButton.iconOnly(
              icon: const CarbonIcon(CarbonIcons.undo),
              semanticLabel: 'Undo',
              onPressed: hasMarks ? onUndo : null,
            ),
            CarbonButton.iconOnly(
              icon: const CarbonIcon(CarbonIcons.erase),
              semanticLabel: 'Clear',
              onPressed: hasMarks ? onClear : null,
            ),
            const _BarDivider(),
            CarbonButton.iconOnly(
              icon: const CarbonIcon(CarbonIcons.close),
              semanticLabel: 'Close',
              onPressed: onClose,
            ),
            const SizedBox(width: CarbonSpacing.spacing03),
            if (compact)
              CarbonButton.iconOnly(
                icon: const CarbonIcon(CarbonIcons.send),
                semanticLabel: 'Send',
                kind: CarbonButtonKind.primary,
                busy: busy,
                onPressed: onSend,
              )
            else
              CarbonButton(label: 'Send', busy: busy, onPressed: onSend),
          ],
    );
  }
}

const double _kCompactBarWidth = 360;

class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: CarbonSpacing.spacing02),
    child: SizedBox(
      width: CarbonBorders.hairline,
      height: CarbonSpacing.spacing05,
      child: ColoredBox(color: CarbonTheme.of(context).colors.borderStrong01),
    ),
  );
}

/// Current pen color as a single swatch button that opens the palette in a
/// popup, rather than laying all five swatches inline in the toolbar row.
///
/// The inline row used to sit inside the same scrollable cluster as the
/// tools, so on a narrow preview panel it was squeezed out of the visible
/// width entirely — reachable only by swiping the toolbar itself, which read
/// as the palette simply being gone. One fixed-width trigger has nothing left
/// to squeeze out.
class _ColorPickerCell extends StatefulWidget {
  const _ColorPickerCell({required this.pen, required this.onPen});

  final _PenColor pen;
  final ValueChanged<_PenColor> onPen;

  @override
  State<_ColorPickerCell> createState() => _ColorPickerCellState();
}

class _ColorPickerCellState extends State<_ColorPickerCell> {
  final CarbonPopupController _popup = CarbonPopupController();

  /// The popup binds Escape on its anchor's subtree, and a tap on an icon
  /// button does not move focus, so the trigger takes it explicitly or Escape
  /// would miss the popup and reach the overlay.
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'PenColorTrigger');

  @override
  void dispose() {
    _triggerFocus.dispose();
    _popup.dispose();
    super.dispose();
  }

  void _pick(_PenColor pen) {
    _popup.close();
    widget.onPen(pen);
  }

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return CarbonAnchoredPopup(
      controller: _popup,
      preferAbove: true,
      gap: CarbonSpacing.spacing02,
      popupBuilder: (popupContext, available) {
        final theme = CarbonTheme.of(popupContext);
        final level = CarbonLayer.of(popupContext);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.layer(level),
            border: Border.all(color: theme.borderSubtle(level)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: theme.colors.shadow,
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(CarbonSpacing.spacing02),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in _PenColor.values)
                  CarbonButton.iconOnly(
                    icon: _Swatch(color: option.resolve(theme.colors)),
                    semanticLabel: option.label,
                    selected: option == widget.pen,
                    onPressed: () => _pick(option),
                  ),
              ],
            ),
          ),
        );
      },
      child: CarbonButton.iconOnly(
        icon: _Swatch(color: widget.pen.resolve(colors)),
        semanticLabel: 'Pen color',
        focusNode: _triggerFocus,
        onPressed: () {
          _triggerFocus.requestFocus();
          _popup.toggle();
        },
      ),
    );
  }
}
