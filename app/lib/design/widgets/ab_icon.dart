import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Renders an Iconify SVG string as a crisp vector icon.
class AbIcon extends StatelessWidget {
  const AbIcon(this.icon, {super.key, this.size = 24, this.color});

  final String icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      icon,
      width: size,
      height: size,
      colorFilter: color != null
          ? ColorFilter.mode(color!, BlendMode.srcIn)
          : null,
    );
  }
}
