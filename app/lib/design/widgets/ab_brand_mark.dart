import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Brand lockup: the outlined "antgrid" wordmark with elbowed ant antennae
/// rising off the 'a' — a circuit-trace read (45° bend, via-dot tips) in the
/// indigo accent. Ink/accent are baked into the asset to match the dark
/// palette; use assets/logo/antgrid-wordmark-light.svg on light backgrounds.
/// The 2x2 diagonal grid remains the icon-scale identity (favicon, launcher).
class AbBrandMark extends StatelessWidget {
  const AbBrandMark({super.key, this.height = 20});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/logo/antgrid-wordmark.svg',
      height: height,
      semanticsLabel: 'antgrid',
    );
  }
}
