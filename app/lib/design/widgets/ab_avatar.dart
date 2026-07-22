import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

class AbAvatar extends StatelessWidget {
  const AbAvatar({super.key, required this.name, this.size = 22});

  final String name;
  final double size;

  String get _initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final words = trimmed.split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return (words[0][0] + words[1][0]).toUpperCase();
    }
    return trimmed.length >= 2
        ? trimmed.substring(0, 2).toUpperCase()
        : trimmed.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: palette.bgRaised,
        border: Border.all(color: palette.borderDefault),
        borderRadius: AbTokens.borderRadiusFull,
      ),
      alignment: Alignment.center,
      child: Text(
        _initials,
        style: TextStyle(
          fontFamily: AbTokens.fontSans,
          fontSize: size * 0.5,
          color: palette.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
