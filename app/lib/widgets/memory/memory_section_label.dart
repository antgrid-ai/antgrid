import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// The heading above a group of fields or facts on Memory surfaces.
class MemorySectionLabel extends StatelessWidget {
  const MemorySectionLabel(
    this.text, {
    super.key,
    this.top = 0,
    this.bottom = CarbonSpacing.spacing03,
  });

  final String text;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: t.typography.heading.copyWith(color: t.colors.textPrimary),
        ),
      ),
    );
  }
}
