import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path_parsing/path_parsing.dart';

import 'theme.dart';

part 'icons.g.dart';

/// Paints a bundled Carbon glyph.
///
/// Decorative by default: with no [semanticLabel] the icon is excluded from
/// semantics so the control that owns it announces once. Icon-only controls
/// must label the control, not the icon.
///
/// Controls that accept an icon take any [Widget], so a consumer may pass its
/// own icon widget instead; size it with [CarbonThemeData.iconSize].
class CarbonIcon extends StatelessWidget {
  const CarbonIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.innerColor,
    this.semanticLabel,
  });

  final CarbonIcons icon;

  /// Defaults to the theme's density-resolved [CarbonThemeData.iconSize].
  final double? size;

  /// Defaults to the nearest [IconTheme] color, then `iconPrimary`.
  final Color? color;

  /// Fills the glyph's inner mark (the "!" in [CarbonIcons.warningFilled]) for
  /// contrast against the outer shape. Unpainted when null, which leaves the
  /// mark transparent as in Carbon's outline rendering.
  final Color? innerColor;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final resolvedSize = size ?? IconTheme.of(context).size ?? theme.iconSize;
    final resolvedColor =
        color ?? IconTheme.of(context).color ?? theme.colors.iconPrimary;
    final mirror =
        icon.mirrorsInRtl && Directionality.maybeOf(context) == TextDirection.rtl;
    Widget glyph = CustomPaint(
      size: Size.square(resolvedSize),
      painter: _CarbonIconPainter(
        icon: icon,
        color: resolvedColor,
        innerColor: innerColor,
        mirror: mirror,
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: glyph);
    return Semantics(label: semanticLabel, image: true, child: glyph);
  }
}

class _CarbonIconPath {
  const _CarbonIconPath(this.data, {this.rotation});

  final String data;

  /// `[degrees, cx, cy]`, from an SVG `rotate()` transform.
  final List<double>? rotation;
}

class _CarbonGlyph {
  const _CarbonGlyph(this.outer, {this.inner = const <_CarbonIconPath>[]});

  final List<_CarbonIconPath> outer;
  final List<_CarbonIconPath> inner;
}

/// Parsed glyph geometry in the 32-unit grid. Parsing is pure and the inputs
/// are compile-time constants, so a process-wide cache can never go stale.
final Map<CarbonIcons, (ui.Path, ui.Path?)> _parsed =
    <CarbonIcons, (ui.Path, ui.Path?)>{};

(ui.Path, ui.Path?) _geometry(CarbonIcons icon) {
  return _parsed.putIfAbsent(icon, () {
    final glyph = _glyphs[icon]!;
    ui.Path combine(List<_CarbonIconPath> parts) {
      final path = ui.Path();
      for (final part in parts) {
        final proxy = _PathProxy();
        writeSvgPathDataToPath(part.data, proxy);
        var piece = proxy.path;
        final r = part.rotation;
        if (r != null) {
          final m = Matrix4.identity()
            ..translateByDouble(r[1], r[2], 0, 1)
            ..rotateZ(r[0] * 3.141592653589793 / 180)
            ..translateByDouble(-r[1], -r[2], 0, 1);
          piece = piece.transform(m.storage);
        }
        path.addPath(piece, Offset.zero);
      }
      return path;
    }

    return (
      combine(glyph.outer),
      glyph.inner.isEmpty ? null : combine(glyph.inner),
    );
  });
}

class _PathProxy extends PathProxy {
  final ui.Path path = ui.Path();

  @override
  void close() => path.close();

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
}

class _CarbonIconPainter extends CustomPainter {
  _CarbonIconPainter({
    required this.icon,
    required this.color,
    required this.innerColor,
    required this.mirror,
  });

  final CarbonIcons icon;
  final Color color;
  final Color? innerColor;
  final bool mirror;

  @override
  void paint(Canvas canvas, Size size) {
    final (outer, inner) = _geometry(icon);
    canvas.save();
    if (mirror) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.scale(size.width / 32, size.height / 32);
    canvas.drawPath(outer, Paint()..color = color);
    final fill = innerColor;
    if (inner != null && fill != null) {
      canvas.drawPath(inner, Paint()..color = fill);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CarbonIconPainter old) =>
      old.icon != icon ||
      old.color != color ||
      old.innerColor != innerColor ||
      old.mirror != mirror;
}
