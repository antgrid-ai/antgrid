import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Brand lockup: the outlined "antgrid" wordmark with elbowed ant antennae
/// rising off the 'a' — a circuit-trace read (45° bend, via-dot tips) in the
/// indigo accent. Ink/accent are baked into the asset to match the dark
/// palette; use assets/logo/antgrid-wordmark-light.svg on light backgrounds.
///
/// [AbBrandMark.icon] is the square 'a'-glyph mark, for slots too narrow for
/// the 2.88:1 wordmark.
class AbBrandMark extends StatelessWidget {
  const AbBrandMark({super.key, this.height = 20})
    : _asset = 'assets/logo/antgrid-wordmark.svg';

  /// Square mark for tight slots such as the window title bar.
  ///
  /// Uses the transparent variant: the plated `antgrid-mark.svg` paints a
  /// #18181B tile on a #09090B bar, which reads as elevation.
  const AbBrandMark.icon({super.key, this.height = iconHeight})
    : _asset = 'assets/logo/antgrid-mark-transparent.svg';

  /// Default height of [AbBrandMark.icon] — and its width, the mark being
  /// square. Exposed so a layout that reserves room for the mark can add it up
  /// without measuring (the window title bar's centred search box does).
  static const double iconHeight = 18;

  final double height;
  final String _asset;

  @override
  Widget build(BuildContext context) {
    // No colorFilter: the mark is already two-tone (#FAFAFA glyph, #818CF8
    // antennae and via-dots) and tinting would flatten it.
    return SvgPicture.asset(_asset, height: height, semanticsLabel: 'antgrid');
  }
}
