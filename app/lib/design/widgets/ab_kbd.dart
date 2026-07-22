import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

class AbKbd extends StatelessWidget {
  const AbKbd(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.bgRaised,
        borderRadius: AbTokens.borderRadius5,
        border: Border.all(color: p.borderDefault),
        boxShadow: [
          BoxShadow(
            color: p.borderStrong,
            offset: const Offset(0, 1),
            blurRadius: 0,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Text(
        label,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          fontWeight: FontWeight.w500,
          color: p.textSecondary,
        ),
      ),
    );
  }
}

class AbKbdGroup extends StatelessWidget {
  const AbKbdGroup(this.keys, {super.key});
  final List<String> keys;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          AbKbd(keys[i]),
        ],
      ],
    );
  }
}
