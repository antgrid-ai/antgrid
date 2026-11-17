import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

enum MemoryTagSize { row, detail, detailCompact }

class MemoryTag extends StatelessWidget {
  const MemoryTag({
    super.key,
    required this.label,
    this.filled = false,
    this.size = MemoryTagSize.row,
  });

  final String label;
  final bool filled;
  final MemoryTagSize size;

  @override
  Widget build(BuildContext context) => CarbonTag(
    label: label,
    size: size == MemoryTagSize.detailCompact
        ? CarbonTagSize.medium
        : CarbonTagSize.small,
    color: filled ? CarbonTagColor.highContrast : CarbonTagColor.gray,
  );
}
