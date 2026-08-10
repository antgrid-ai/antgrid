import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../providers/app_version.dart';
import '../../util/external_url.dart';

/// Body rows of the settings HELP section. Renders rows only — the `_Section`
/// frame is private to `app_settings_screen.dart`, which mounts this inside it.
class HelpAboutSection extends ConsumerWidget {
  const HelpAboutSection({super.key, this.openUrl = openExternalUrl});

  /// Injectable so tests capture URLs instead of launching a browser.
  final Future<void> Function(BuildContext, String) openUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final antgrid = context.antgrid;
    // Resolves within a frame; render blank rather than a spinner meanwhile.
    final version = ref.watch(appVersionLabelProvider).asData?.value ?? '';
    return Column(
      children: [
        _LinkRow(
          label: 'Getting started',
          onTap: () => openUrl(context, 'https://antgrid.ai/get-started'),
        ),
        _LinkRow(
          label: 'Support',
          onTap: () => openUrl(context, 'https://antgrid.ai/support'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
          child: Row(
            children: [
              Text(
                'Version',
                style: AbTokens.sansStyle(color: antgrid.textPrimary),
              ),
              const Spacer(),
              Text(
                version,
                // Version string is data, not chrome — mono.
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: antgrid.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Same row anatomy as the screen's 'Pricing' row so the settings list scans
/// as one surface.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return InkWell(
      onTap: onTap,
      borderRadius: AbTokens.borderRadius,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
        child: Row(
          children: [
            Text(label, style: AbTokens.monoStyle(color: antgrid.textPrimary)),
            const Spacer(),
            AbIconButton(icon: AbIcons.chevronRight, onTap: onTap),
          ],
        ),
      ),
    );
  }
}
