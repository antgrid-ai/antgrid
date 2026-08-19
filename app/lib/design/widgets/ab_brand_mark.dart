import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../ab_colors.dart';

/// The Antgrid brand, in the three cuts the app shell needs.
///
/// The mark is Converge: four chevrons — one per agent — closing on a single
/// accent target, the one under command. The target keeps its #D2542A on every
/// ground; only the ink flips, so each cut ships as an ink/paper pair and this
/// widget picks by palette luminance. A background can be light
/// (`AbThemePreset.light` ships, and a custom one is free-form), and paper ink
/// on a paper surface is invisible.
///
/// Which cut to reach for follows the brand's reduction rule — the four agents
/// need [_fourAgentFloor] to stay apart:
///  * [AbBrandMark] — the wordmark alone, for narrow chrome such as the drawer.
///  * [AbBrandMark.lockup] — mark plus wordmark, for slots with room to give it
///    (sign-in, the auth splash).
///  * [AbBrandMark.icon] — the square mark, for slots too narrow for type. It
///    applies the reduction rule itself rather than making callers know it.
class AbBrandMark extends StatelessWidget {
  const AbBrandMark({super.key, this.height = 20}) : _cut = 'wordmark';

  /// Mark and wordmark together — the brand's primary lockup.
  ///
  /// The default clears the four-agent floor for the mark inside it; below
  /// roughly [lockupHeight] the mark blurs and the bare wordmark reads better.
  const AbBrandMark.lockup({super.key, this.height = lockupHeight})
    : _cut = 'mark+word';

  /// Square mark for tight slots such as the window title bar.
  ///
  /// Uses a tileless variant: the plated `antgrid-mark.svg` paints a #101418
  /// tile on a #09090B bar, which reads as elevation.
  const AbBrandMark.icon({super.key, this.height = iconHeight}) : _cut = 'mark';

  /// Default height of [AbBrandMark.icon] — and its width, the mark being
  /// square. Exposed so a layout that reserves room for the mark can add it up
  /// without measuring (the window title bar's centred search box does).
  static const double iconHeight = 18;

  /// Default height of [AbBrandMark.lockup]. The lockup is mostly type, so the
  /// mark inside it lands near the four-agent floor only once the whole thing
  /// is this tall.
  static const double lockupHeight = 44;

  /// Below this the four chevrons smear into each other and the two-agent cut
  /// reads better. Same threshold the generator tiers its rasters on
  /// (`tierFor` in `scripts/gen-brand-icons.ts`) — keep them in lockstep.
  static const double _fourAgentFloor = 40;

  final double height;
  final String _cut;

  /// The asset a cut resolves to at [height] under [palette].
  ///
  /// Public so a test can name the expected file without restating the naming
  /// scheme.
  static String assetFor(String cut, AbColors palette, double height) {
    final base = switch (cut) {
      'mark' => height < _fourAgentFloor ? 'mark-small' : 'mark-transparent',
      'mark+word' => 'lockup',
      _ => cut,
    };
    final onLight = palette.bgDeepest.computeLuminance() > 0.5;
    return 'assets/logo/antgrid-$base${onLight ? '-light' : ''}.svg';
  }

  @override
  Widget build(BuildContext context) {
    // No colorFilter: every cut is two-tone (ink chevrons, #D2542A target) and
    // tinting would flatten it — hence a second file per cut instead.
    return SvgPicture.asset(
      assetFor(_cut, context.antgrid, height),
      height: height,
      semanticsLabel: 'Antgrid',
    );
  }
}
